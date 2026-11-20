//
//  DelegateDispatch.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines

/// The delegate's fan-out/gather site — a thin composition over structured concurrency and
/// ``SpawnBudget``, not a runtime. Runs a set of sub-tasks concurrently, bounded by the shared budget,
/// and gathers their results in task order.
///
/// This is where the termination invariant is *enforced*: every fan-out reserves budget up front and
/// **refuses at zero** rather than spawning unconditionally, so a recursive delegate can never outrun its
/// cap. Recursion is expressed by the `worker` receiving the same shared `budget` — a subagent simply
/// calls `dispatch` again for its own children (Phase 0.3 showed this composes).
///
/// - Author: Claude
public enum DelegateDispatch {

    /// Fan out over `tasks`, running each through `worker` concurrently under `budget`.
    ///
    /// One descent unit is reserved per task up front (reservation-on-descent). If the budget grants
    /// fewer than `tasks.count`, the surplus tail tasks are **not spawned** — each is filled with
    /// `exhausted(task)` instead. Results are returned in `tasks` order regardless of completion order.
    ///
    /// - Parameters:
    ///   - tasks: The sub-tasks to fan out over.
    ///   - budget: The delegate-wide spawn budget, shared with every descendant.
    ///   - worker: Solves one sub-task; receives the shared `budget` so it can recurse.
    ///   - exhausted: Produces a graceful result for a task the budget refused to spawn.
    public static func dispatch<Task: Sendable, Result: Sendable>(
        _ tasks: [Task],
        budget: SpawnBudget,
        worker: @Sendable @escaping (Task, SpawnBudget) async throws -> Result,
        exhausted: @Sendable (Task) -> Result
    ) async throws -> [Result] {
        let granted = await budget.reserve(tasks.count)

        // Pre-fill every slot with its refused placeholder (refuse-at-zero for the tail beyond the grant),
        // then overwrite the granted head with worker results. Building `[Result]` directly — rather than
        // `[Result?]` gathered with `compactMap` — keeps a strict 1:1 correspondence with `tasks` by
        // construction: no index can be silently dropped or reordered if one were ever left unfilled.
        var results = tasks.map(exhausted)
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            for (index, task) in tasks.enumerated() where index < granted {
                group.addTask { (index, try await worker(task, budget)) }
            }
            for try await (index, result) in group {
                results[index] = result
            }
        }
        return results
    }

    /// Speculative fan-out with **kill-the-losers**: run the tasks concurrently under `budget` and,
    /// the moment the accumulated results satisfy `isSatisfied`, cancel every still-running subagent —
    /// reclaiming their inference slots immediately. Cancellation cascades through structured
    /// concurrency: cancelling a losing worker cancels the whole subtree it spawned (nested
    /// `dispatch`/`PipelineRunner.run` unwind at their next suspension point).
    ///
    /// Returns the results collected up to (and including) the one that satisfied the policy, in
    /// completion order. Losing tasks contribute nothing.
    public static func dispatchUntil<Task: Sendable, Result: Sendable>(
        _ tasks: [Task],
        budget: SpawnBudget,
        isSatisfied: @Sendable @escaping ([Result]) -> Bool,
        worker: @Sendable @escaping (Task, SpawnBudget) async throws -> Result
    ) async throws -> [Result] {
        let granted = await budget.reserve(tasks.count)
        guard granted > 0 else { return [] }

        return try await withThrowingTaskGroup(of: Result.self) { group in
            for index in 0..<granted {
                let task = tasks[index]
                group.addTask { try await worker(task, budget) }
            }
            var collected: [Result] = []
            for try await result in group {
                collected.append(result)
                if isSatisfied(collected) {
                    group.cancelAll()   // kill the losers — cascades to their subtrees
                    break
                }
            }
            return collected
        }
    }

    /// Fan out over terminal **leaf** `tasks` — the nodes that do the actual work and never recurse.
    ///
    /// Each leaf claims a slot with ``SpawnBudget/tryAcquireLeafSlot()``, which draws on the budget's
    /// dedicated leaf reserve first. This guarantees **forward progress**: at least `leafReserve`
    /// leaves always run even when branch fan-out has drained the descent pool, so a delegate can never
    /// spend its whole budget building structure while no actual work completes. Refused leaves get
    /// `exhausted(task)`.
    ///
    /// Slots are claimed sequentially before spawning so the guarantee is deterministic (the leaf
    /// reserve is honoured regardless of concurrent scheduling). The `worker` takes no budget — a leaf
    /// is terminal by definition.
    public static func dispatchLeaves<Task: Sendable, Result: Sendable>(
        _ tasks: [Task],
        budget: SpawnBudget,
        worker: @Sendable @escaping (Task) async throws -> Result,
        exhausted: @Sendable (Task) -> Result
    ) async throws -> [Result] {
        var admitted = [Bool](repeating: false, count: tasks.count)
        for index in tasks.indices {
            admitted[index] = await budget.tryAcquireLeafSlot()
        }

        // Pre-fill refused placeholders, then overwrite admitted leaves with worker results — a strict
        // `[Result]` with 1:1 `tasks` correspondence by construction (see `dispatch` for the rationale).
        var results = tasks.map(exhausted)
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            for (index, task) in tasks.enumerated() where admitted[index] {
                group.addTask { (index, try await worker(task)) }
            }
            for try await (index, result) in group {
                results[index] = result
            }
        }
        return results
    }
}
