//
//  SelfCloningResearchPipelineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
@testable import Examples
@testable import ExecutionEngine

/// End-to-end execution of ``SelfCloningResearchPipeline`` through the real walker with a scripted
/// backend: the agent decomposes its topic and delegates each sub-topic to a delegate of itself, bottoming
/// out at atomic topics — proving self-recursion runs, terminates on data, and gathers/combines.
final class SelfCloningResearchPipelineTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func inc() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// A leaf prompt ("Answer this concisely") echoes its topic; a combine prompt yields "combined".
    private func scripted(_ calls: Counter) -> ScriptedExecutor {
        ScriptedExecutor { call in
            calls.inc()
            if call.input.contains("Combine these into one") {
                return ScriptedExecutor.string("combined")
            }
            return ScriptedExecutor.string("leaf")
        }
    }

    func testRecursivelyDecomposesAndCombines() async throws {
        // 8 words → depth-2 tree: root → 2 halves → each 2 leaves. Every node runs one model turn.
        let calls = Counter()
        let (result, _) = try await PipelineRun.runReactive(
            SelfCloningResearchPipeline(topic: "one two three four five six seven eight"),
            executor: scripted(calls))

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "combined",
                       "the root is an internal node — it combines its delegates' answers")
        XCTAssertGreaterThanOrEqual(calls.value, 4,
                                    "the agent recursed into multiple self-delegates (not a single pass)")
    }

    func testAtomicTopicAnswersDirectlyWithoutCloning() async throws {
        // ≤ 2 words is atomic: no decomposition, no delegates — a single leaf answer.
        let calls = Counter()
        let (result, _) = try await PipelineRun.runReactive(
            SelfCloningResearchPipeline(topic: "one two"),
            executor: scripted(calls))

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "leaf",
                       "an atomic topic is answered directly")
        XCTAssertEqual(calls.value, 1, "no delegates were spawned for an atomic topic")
    }
}
