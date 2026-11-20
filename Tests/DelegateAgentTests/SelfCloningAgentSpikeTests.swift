//
//  SelfCloningAgentSpikeTests.swift
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

/// Self-cloning agent — Phase 0 spike (dynamic path).
///
/// **Go/no-go:** can a *single* pipeline type spawn delegates of **itself** and terminate? The existing
/// recursion spike used distinct types per level (`DelegateBranchDispatch` → `DelegateBranchSpike` →
/// `DelegateLeafSpike`); the budget spike proved unbounded recursion terminates via `SpawnBudget`. Neither
/// proved the self-similar shape the design needs: `Agent` running `Agent`.
///
/// **Result: composes and terminates.** The key insight: `body` is built *finitely* — it is one
/// `ClientTask` leaf — and the recursion happens at **runtime**, inside that closure, which runs
/// `PipelineRunner.run(SelfCloningAgentSpike(depth: depth + 1, …))`. So a self-referential agent never
/// expands at build/lower time; a depth cap and a monotone `SpawnBudget` make the runtime tree finite.
/// This is exactly the mechanism Phase 1 promotes into a first-class self-recursion leaf.
final class SelfCloningAgentSpikeTests: XCTestCase {

    func testSelfSimilarRecursionComposesAndTerminates() async throws {
        let budget = SpawnBudget(total: 64, leafReserve: 0)
        let executor = SpikeNoopExecutor()

        let out = try await PipelineRunner.run(
            SelfCloningAgentSpike(task: "r", depth: 0, maxDepth: 2, fanout: 2, budget: budget, executor: executor),
            executor: executor)
        let tree = (try? JSONDecoder().decode(String.self, from: out)) ?? ""

        // depth 0 fans out to 2; each depth-1 fans out to 2; depth 2 == maxDepth ⇒ leaves ("leaf:…").
        XCTAssertEqual(tree, "r:[r.0:[leaf:r.0.0,leaf:r.0.1],r.1:[leaf:r.1.0,leaf:r.1.1]]",
                       "a self-similar agent spawns delegates of itself and gathers their subtrees in order")
    }

    func testUnboundedSelfRecursionTerminatesByBudgetAlone() async throws {
        // No effective depth cap: only the budget can stop the recursion (mirrors the design's
        // guarantee that budget alone bounds an unbounded self-delegate tree).
        let total = 32
        let budget = SpawnBudget(total: total, leafReserve: 0)
        let executor = SpikeNoopExecutor()

        // Completing at all proves termination + deadlock-freedom under saturation.
        _ = try await PipelineRunner.run(
            SelfCloningAgentSpike(task: "r", depth: 0, maxDepth: .max, fanout: 3, budget: budget, executor: executor),
            executor: executor)

        let leftover = await budget.available
        XCTAssertGreaterThanOrEqual(leftover, 0, "budget is never over-drawn")
        XCTAssertLessThanOrEqual(total - leftover, total, "spawns never exceed the budget cap")
    }
}

// MARK: - Self-similar spike pipeline (Agent runs Agent)

/// A pipeline whose `body` is one `ClientTask` that, at runtime, spawns delegates of **itself** (one level
/// deeper) for each sub-task and gathers them — until the depth cap or the shared budget stops it.
/// `budget`/`executor` are threaded by **capture** (an actor budget can't ride in `@State`).
private struct SelfCloningAgentSpike: Pipeline {
    typealias Output = String

    @State var task: String
    let depth: Int
    let maxDepth: Int
    let fanout: Int
    let budget: SpawnBudget
    let executor: any Executor

    @State var result = ""

    init(task: String, depth: Int, maxDepth: Int, fanout: Int, budget: SpawnBudget, executor: any Executor) {
        self._task = State(wrappedValue: task)
        self.depth = depth
        self.maxDepth = maxDepth
        self.fanout = fanout
        self.budget = budget
        self.executor = executor
    }

    var body: some Pipeline {
        $result.set {
            ClientTask(input: $task) { [depth, maxDepth, fanout, budget, executor] task in
                guard depth < maxDepth else { return "leaf:\(task)" }
                // Reservation-on-descent: claim this node's fan-out before spawning; refuse at zero.
                let granted = await budget.reserve(fanout)
                guard granted > 0 else { return "leaf:\(task)" }

                let children = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                    for index in 0..<granted {
                        group.addTask { [executor] in
                            let output = try await PipelineRunner.run(
                                SelfCloningAgentSpike(
                                    task: "\(task).\(index)", depth: depth + 1, maxDepth: maxDepth,
                                    fanout: fanout, budget: budget, executor: executor),
                                executor: executor)
                            return (index, (try? JSONDecoder().decode(String.self, from: output)) ?? "")
                        }
                    }
                    var results = [String](repeating: "", count: granted)
                    for try await (index, value) in group { results[index] = value }
                    return results
                }
                return "\(task):[\(children.joined(separator: ","))]"
            }
        }
        $result.get()
    }
}

/// Minimal executor: the spike is pure `ClientTask` recursion, so no model call is ever made.
private struct SpikeNoopExecutor: Executor {
    func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        try JSONEncoder().encode("")
    }
}
