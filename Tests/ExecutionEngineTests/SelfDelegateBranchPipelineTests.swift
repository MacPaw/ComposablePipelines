//
//  SelfDelegateBranchPipelineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
import PipelineDSL
@testable import ExecutionEngine

/// Proves the exact construct combination the Xcode `SelfDelegateDemoPipeline` relies on but which no
/// other test covers end-to-end: a **slot-driven `When($split)`** whose *then*-branch spawns a
/// **`DelegateSelf`** clone tree. The tested `SelfCloningResearchPipeline` always delegates (empty parts
/// ⇒ leaf); the demo instead *branches* on a `Bool` slot and only the split branch recurses — so a
/// clone (a static walk with no `graphProvider`) must both evaluate the in-graph branch *and*, inside
/// it, drive further self-delegation. This runs that structure through the real walker.
final class SelfDelegateBranchPipelineTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func inc() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// Structurally identical to `SelfDelegateDemoPipeline`: the model decides decomposition, the split
    /// is a `Bool` slot, and `When($split)` wraps the `DelegateSelf` recursion.
    private struct BranchingSelfAgent: Pipeline {
        typealias Output = String
        let topic: String
        @State("current") var current: String = ""
        @State("effective") var effective: String = ""
        @State("raw") var raw: String = ""
        @State("parts") var parts: [String] = []
        @State("split") var split = false
        @State("answers") var answers: [String?] = []
        @State("digest") var digest: String = ""
        @State("answer") var answer: String = ""

        var body: some Pipeline {
            $effective.set { Run(input: $current) { [topic] c in c.isEmpty ? topic : c } }
            $raw.set {
                Model<String>.chat(systemPrompt: "decompose")
                    .input { $effective.get() }
            }
            $parts.set { Run(input: $raw) { Self.parse($0) } }
            $split.set { Run(input: $parts) { !$0.isEmpty } }

            When($split) {
                $answers.set {
                    DelegateSelf<String, String>(
                        tasks: $parts, taskInput: $current,
                        budget: .init(total: 32, leafReserve: 4), inherit: [.tools])
                }
                $digest.set {
                    Run($effective, $answers) { _, answers in
                        "Combine these into one: " + answers.compactMap { $0 }.joined(separator: " | ")
                    }
                }
                $answer.set {
                    Model<String>.chat(systemPrompt: "combine").input { $digest.get() }
                }
            } else: {
                $answer.set {
                    Model<String>.chat(systemPrompt: "answer").input { $effective.get() }
                }
            }

            $answer.get()
        }

        /// Best-effort JSON-array parse (mirrors the demo's `parseSubtopics`).
        static func parse(_ raw: String) -> [String] {
            guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start <= end,
                  let data = String(raw[start...end]).data(using: .utf8),
                  let items = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return items
        }
    }

    /// The model halves a >2-word topic into a JSON array (splittable) or returns `[]` (atomic); a
    /// combine turn yields "combined", a leaf answer yields "leaf".
    private func scripted(_ calls: Counter) -> ScriptedExecutor {
        ScriptedExecutor { call in
            calls.inc()
            switch call.instructions {
            case "decompose":
                let words = call.input.split(separator: " ")
                guard words.count > 2 else { return ScriptedExecutor.string("[]") }
                let mid = words.count / 2
                let left = words[..<mid].joined(separator: " ")
                let right = words[mid...].joined(separator: " ")
                let json = try! JSONEncoder().encode([left, right])
                return ScriptedExecutor.string(String(decoding: json, as: UTF8.self))
            case "combine":
                return ScriptedExecutor.string("combined")
            default:
                return ScriptedExecutor.string("leaf")
            }
        }
    }

    func testSplitBranchRecursesThroughSelfDelegation() async throws {
        let calls = Counter()
        let (result, _) = try await PipelineRun.runReactive(
            BranchingSelfAgent(topic: "one two three four five six seven eight"),
            executor: scripted(calls))

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "combined",
                       "the split branch fired: the root combined its self-delegates' answers")
        XCTAssertGreaterThanOrEqual(calls.value, 4,
                                    "recursion ran through the When(split) branch, not a single pass")
    }

    func testAtomicTopicTakesElseBranchWithoutDelegating() async throws {
        let calls = Counter()
        let (result, _) = try await PipelineRun.runReactive(
            BranchingSelfAgent(topic: "one two"),
            executor: scripted(calls))

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "leaf",
                       "atomic topic took the else branch and answered directly")
        // One decompose turn + one leaf answer turn; no delegates ⇒ no extra model calls.
        XCTAssertEqual(calls.value, 2, "else branch: decompose + answer only, no self-delegation")
    }
}
