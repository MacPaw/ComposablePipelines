//
//  DelegateBudgetIntegrationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL
import ExecutionEngine
import ComposablePipelines
import DelegateAgent

/// Phase 1.4 — integration test across dispatch → walker → executor with a scripted backend. An
/// aggressively recursive delegate (every node does model work *and* tries to fan out, no depth cap) is
/// driven through the real `PipelineRunner` execution path. The budget alone must make it terminate,
/// keep the number of model calls (spawns) within the cap, and avoid any hang under saturation.
final class DelegateBudgetIntegrationTests: XCTestCase {

    func testAggressiveRecursiveDelegateTerminatesWithinBudget() async throws {
        let total = 40
        let budget = SpawnBudget(total: total, leafReserve: 0)
        let modelCalls = CallCounter()
        let executor = CountingExecutor(counter: modelCalls)
        let delegate = ScriptedRecursiveDelegate(executor: executor, fanOut: 3)

        let output = try await PipelineRunner.run(
            DelegateBudgetPipeline(seedCount: 3, budget: budget, delegate: delegate),
            executor: executor
        )
        let nodes = try JSONDecoder().decode(Int.self, from: output)

        let calls = await modelCalls.value
        XCTAssertGreaterThan(nodes, 0, "the delegate must do real work")
        XCTAssertEqual(nodes, calls, "every spawned node makes exactly one model call")
        XCTAssertLessThanOrEqual(calls, total, "spawns (model calls) must never exceed the budget cap")
        let leftover = await budget.available
        XCTAssertEqual(leftover, 0, "an unbounded recursion drains the budget")
    }

    func testWideSaturationStillTerminates() async throws {
        let total = 200
        let budget = SpawnBudget(total: total, leafReserve: 4)
        let modelCalls = CallCounter()
        let executor = CountingExecutor(counter: modelCalls)
        let delegate = ScriptedRecursiveDelegate(executor: executor, fanOut: 6)

        // 20 seeds × fan-out 6, no depth cap — heavy saturation. Completing at all proves no deadlock.
        let output = try await PipelineRunner.run(
            DelegateBudgetPipeline(seedCount: 20, budget: budget, delegate: delegate),
            executor: executor
        )
        let nodes = try JSONDecoder().decode(Int.self, from: output)

        let calls = await modelCalls.value
        XCTAssertLessThanOrEqual(calls, total, "spawns must never exceed the budget cap under saturation")
        XCTAssertEqual(nodes, calls)
    }
}

// MARK: - Recursive delegate whose only bound is the budget

private struct ScriptedRecursiveDelegate: Sendable {
    let executor: any Executor
    let fanOut: Int

    @Sendable
    func run(_ task: Int, _ budget: SpawnBudget) async throws -> Int {
        // This node's own work: one model turn through the real walker + scripted executor.
        _ = try await PipelineRunner.run(NodeWork(task: task), executor: executor)
        // Then it unconditionally tries to spawn children — only the budget stops the recursion.
        let children = try await DelegateDispatch.dispatch(
            Array(0..<fanOut),
            budget: budget,
            worker: run,
            exhausted: { _ in 0 }
        )
        return 1 + children.reduce(0, +)
    }
}

private struct DelegateBudgetPipeline: Pipeline {
    typealias Output = Int
    let delegate: ScriptedRecursiveDelegate
    let budget: SpawnBudget

    @State var seeds: [Int]
    @State var total = 0

    init(seedCount: Int, budget: SpawnBudget, delegate: ScriptedRecursiveDelegate) {
        self._seeds = State(wrappedValue: Array(0..<seedCount))
        self.budget = budget
        self.delegate = delegate
    }

    var body: some Pipeline {
        $total.set {
            ClientTask(input: $seeds) { [delegate, budget] seeds in
                let results = try await DelegateDispatch.dispatch(
                    seeds, budget: budget, worker: delegate.run, exhausted: { _ in 0 })
                return results.reduce(0, +)
            }
        }
        $total.get()
    }
}

private struct NodeWork: Pipeline {
    typealias Output = String
    let task: Int

    var body: some Pipeline {
        Model<String>().systemPrompt("work").message("\(task)")
    }
}

// MARK: - Scripted backend that counts every model call (== every spawn)

private struct CountingExecutor: Executor {
    let counter: CallCounter

    func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        await counter.increment()
        return try JSONEncoder().encode("ok")
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
