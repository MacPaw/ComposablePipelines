//
//  MemoryProvisionedSelfAgentTests.swift
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

/// Proves the capability story the Xcode `SelfDelegateDemoPipeline` demonstrates — **agentic tools**,
/// **provisioned (atomic) memory**, and **self-delegation** — is *correct* under a self-recursive graph,
/// which no other test covers:
///
/// - **Tools (`inherit: [.tools]`)** — a leaf runs a client-tool step *inside a clone*. An isolated
///   child's tool call is denied (`DelegateOperationTests`); here the clones must produce tool answers,
///   proving the parent's tools reached them.
/// - **Provisioned memory (B — the atomic-context pattern)** — the *root only* recalls and stores; each
///   clone receives its slice as pre-provisioned task data and never touches the store (which it can't
///   reach — `.memory` is *not* inherited). Both memory ops are wrapped in a symmetric `When($isRoot)`,
///   so a clone walks the else branch and never reaches the `memoryQuery`/`memoryStore` leaf. The
///   recording provider's `queries == 1` / `stores == 1` is the proof the guard holds: were a clone to
///   execute the memory leaves, the counts would exceed one (and the missing provider would fail it).
///
/// The whole thing runs through the real walker (`runReactive`) with a scripted tool provider and a
/// recording memory provider.
final class MemoryProvisionedSelfAgentTests: XCTestCase {

    /// The parent-provisioned task a clone receives: its own sub-topic plus the memory slice the parent
    /// recalled for it. Carried as the delegate's task value, so a clone — running with only `.tools` —
    /// sees this and nothing of the parent's store.
    private struct ProvTopic: Codable, Hashable, Sendable {
        let subtopic: String
        let hints: [ContextItem]
        static let empty = ProvTopic(subtopic: "", hints: [])
    }

    private struct MemoryProvisionedSelfAgent: Pipeline {
        typealias Output = String
        let request: String

        @State("current") var current: ProvTopic = .empty
        @State("isRoot") var isRoot = false
        @State("effective") var effective = ""
        @State("hints") var hints: [ContextItem] = []
        @State("parts") var parts: [String] = []
        @State("split") var split = false
        @State("childTasks") var childTasks: [ProvTopic] = []
        @State("answers") var answers: [String?] = []
        @State("answer") var answer = ""
        @State("storedPlan") var storedPlan = MemoryWritePlan(entries: [])

        var body: some Pipeline {
            // This level's topic + whether we are the true root (a clone's `current` is non-empty).
            $effective.set { Run(input: $current) { [request] c in c.subtopic.isEmpty ? request : c.subtopic } }
            $isRoot.set { Run(input: $current) { $0.subtopic.isEmpty } }

            // MEMORY recall — root only. Symmetric `When`: a clone takes the else branch (its provisioned
            // slice) and never walks the `memoryQuery` leaf, so it needs no `.memory`.
            $hints.set {
                When($isRoot) { Memory.recall($effective) }
                else: { Run(input: $current) { $0.hints } }
            }

            // Decompose deterministically (≤ 2 words ⇒ atomic), so the test needs no scripted model.
            $parts.set { Run(input: $effective) { Self.decompose($0) } }
            $split.set { Run(input: $parts) { !$0.isEmpty } }

            When($split) {
                // PROVISION: package each sub-topic with the parent's recalled slice — atomic context.
                $childTasks.set {
                    Run($parts, $hints) { parts, hints in parts.map { ProvTopic(subtopic: $0, hints: hints) } }
                }
                $answers.set {
                    DelegateSelf<ProvTopic, String>(
                        tasks: $childTasks, taskInput: $current,
                        budget: .init(total: 32, leafReserve: 4), inherit: [.tools])
                }
                $answer.set {
                    Run($effective, $answers) { _, answers in
                        "combined(" + answers.compactMap { $0 }.joined(separator: ",") + ")"
                    }
                }
            } else: {
                // AGENTIC leaf: a client-tool step — runs inside a clone iff `.tools` was inherited.
                $answer.set { ClientTask(input: $effective) { "tool(\($0))" } }
            }

            // STORE — root only, same guard. A clone walks the else branch (an empty plan) and never
            // reaches the `memoryStore` leaf.
            $storedPlan.set {
                When($isRoot) {
                    Memory.store {
                        Run(input: $answer) { MemoryWritePlan(entries: [MemoryEntry(id: "answer", text: $0)]) }
                    }
                }
                else: { Just(value: MemoryWritePlan(entries: [])) }
            }

            $answer.get()
        }

        /// Halve a topic by word count; ≤ 2 words is atomic (`[]`), so recursion terminates on data.
        static func decompose(_ topic: String) -> [String] {
            let words = topic.split(separator: " ").map(String.init)
            guard words.count > 2 else { return [] }
            let mid = words.count / 2
            return [words[..<mid].joined(separator: " "), words[mid...].joined(separator: " ")]
        }
    }

    /// Counts recall/store calls so the test can prove memory is touched at the root and nowhere else.
    private final class RecordingMemory: MemoryProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _queries = 0
        private var _stores = 0
        var queries: Int { lock.withLock { _queries } }
        var stores: Int { lock.withLock { _stores } }

        func add(_ entry: MemoryEntry) async throws { lock.withLock { _stores += 1 } }
        func retrieve(id: String) async throws -> MemoryEntry? { nil }
        func query(_ text: String, quality: MemoryQueryQuality) async throws -> [MemoryEntry] {
            lock.withLock { _queries += 1 }
            return [MemoryEntry(id: "e", text: "recalled:\(text)")]
        }
    }

    func testAgenticToolsAndRootOnlyMemoryUnderSelfDelegation() async throws {
        let memory = RecordingMemory()
        // 8 words ⇒ depth-2 self-tree: root → 2 halves → each 2 atomic leaves (client-tool answers).
        let (result, _) = try await PipelineRun.runReactive(
            MemoryProvisionedSelfAgent(request: "one two three four five six seven eight"),
            executor: MockExecutor(),
            clientActionResolver: { _, input in
                // The leaf's client tool: echo the topic as a "tool" answer. Reached only when a clone
                // inherited `.tools`; an isolated clone would be denied and yield nil.
                let topic = (try? JSONDecoder().decode(String.self, from: input)) ?? ""
                return try JSONEncoder().encode("tool(\(topic))")
            },
            memoryProvider: memory)

        let answer = try JSONDecoder().decode(String.self, from: result)
        XCTAssertTrue(answer.hasPrefix("combined("),
                      "the root split and combined its self-delegates' tool answers")
        XCTAssertTrue(answer.contains("tool("),
                      "leaf clones ran the client tool — proof `.tools` was inherited into clones")

        XCTAssertEqual(memory.queries, 1,
                       "only the root recalled memory; clones used their provisioned slice (root-only guard held)")
        XCTAssertEqual(memory.stores, 1,
                       "only the root stored; clones never reached the memoryStore leaf (they lack `.memory`)")
    }

    func testAtomicRequestRecallsAnswersWithToolAndStoresOnce() async throws {
        let memory = RecordingMemory()
        // ≤ 2 words: atomic at the root — no clones. Root recalls, answers via the tool, stores once.
        let (result, _) = try await PipelineRun.runReactive(
            MemoryProvisionedSelfAgent(request: "one two"),
            executor: MockExecutor(),
            clientActionResolver: { _, input in
                let topic = (try? JSONDecoder().decode(String.self, from: input)) ?? ""
                return try JSONEncoder().encode("tool(\(topic))")
            },
            memoryProvider: memory)

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "tool(one two)",
                       "an atomic request is answered directly by the tool")
        XCTAssertEqual(memory.queries, 1, "the root recalled once")
        XCTAssertEqual(memory.stores, 1, "the root stored its answer once")
    }
}
