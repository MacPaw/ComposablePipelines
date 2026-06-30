//
//  WhileLoopReexecutionTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineDSL
@testable import ExecutionEngine

/// A `While` loop that mutates state must advance across iterations until its condition is false,
/// re-running its body each pass (reactive recompilation). Regression coverage for the
/// freeze-guard / cursor-trim interaction that previously stopped such loops after one pass.
final class WhileLoopReexecutionTests: XCTestCase {

    private struct CounterWhile: Pipeline {
        typealias Output = Int
        let target: Int
        @State var count: Int = 0
        var body: some Pipeline {
            While(condition: { count < target }) {
                $count.set { ClientTask(input: $count) { $0 + 1 } }
            }
            $count.get()
        }
    }

    func testCounterLoop_advancesToTarget() async throws {
        let pipeline = CounterWhile(target: 3)
        let (result, events) = try await PipelineRun.runReactive(pipeline, executor: MockExecutor())

        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: result), 3, "Loop output is the final counter value.")
        let history = events.slotHistory(pipeline.$count.id).map { (try? JSONDecoder().decode(Int.self, from: $0)) ?? -1 }
        XCTAssertEqual(history, [1, 2, 3], "Counter advances one per iteration until the condition is false.")
    }

    func testCounterLoop_zeroIterationsWhenConditionInitiallyFalse() async throws {
        let pipeline = CounterWhile(target: 0)
        let (result, events) = try await PipelineRun.runReactive(pipeline, executor: MockExecutor())

        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: result), 0)
        XCTAssertEqual(events.slotHistory(pipeline.$count.id).count, 0, "Body never runs when condition starts false.")
    }

    // MARK: - Multi-step body (commit batching)

    /// Each iteration writes two slots in order. The whole body must run per iteration (commits
    /// batched), not break apart after the first commit.
    private struct MultiStepWhile: Pipeline {
        typealias Output = String
        let target: Int
        @State var count: Int = 0
        @State var log: String = ""
        var body: some Pipeline {
            While(condition: { count < target }) {
                $log.set { ClientTask(input: $count) { prev in "\(prev)" } }
                $count.set { ClientTask(input: $count) { $0 + 1 } }
            }
            $log.get()
        }
    }

    func testMultiStepBody_runsBothWritesEachIteration() async throws {
        let pipeline = MultiStepWhile(target: 3)
        let (result, events) = try await PipelineRun.runReactive(pipeline, executor: MockExecutor())

        // `log` records the count seen at the start of each iteration: 0, 1, 2.
        XCTAssertEqual(events.slotHistoryStrings(pipeline.$log.id), ["0", "1", "2"])
        let counts = events.slotHistory(pipeline.$count.id).map { (try? JSONDecoder().decode(Int.self, from: $0)) ?? -1 }
        XCTAssertEqual(counts, [1, 2, 3], "Both writes land each iteration; count advances.")
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "2")
    }
}
