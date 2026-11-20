//
//  DelegateRunner.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines

/// Runs a flat delegate of subagents while honoring the **shared-model contract**.
///
/// Each `subagent` is expected to run its own pipeline (e.g. `PipelineRunner.run(Worker(task),
/// executor:)`) against the delegate's shared model executor. Because the resource heap coalesces model
/// *loads* but not resource *creation* (the Phase 0.1 cold-start finding), a cold thundering-herd of
/// concurrent subagents could each build their own model instance. `DelegateRunner` prevents that by
/// **warming** the shared model: it runs the first subagent to completion — which loads the model and
/// leaves it resident in the heap — before flooding the rest concurrently, so every follower shares
/// the one warm instance.
///
/// Fan-out is bounded by ``SpawnBudget`` and results are gathered in `tasks` order. This is the flat
/// leaf-flood entry point; recursive delegates compose ``DelegateDispatch`` directly (the worker threads the
/// budget down).
///
/// - Author: Claude
public enum DelegateRunner {

    /// Run `subagent` over every task, warming the shared model first (unless `warmUp` is `false`),
    /// then flooding the remainder concurrently under `budget`. Refused tasks get `exhausted(task)`.
    public static func run<Task: Sendable, Output: Sendable>(
        tasks: [Task],
        budget: SpawnBudget,
        warmUp: Bool = true,
        subagent: @Sendable @escaping (Task) async throws -> Output,
        exhausted: @Sendable @escaping (Task) -> Output
    ) async throws -> [Output] {
        guard !tasks.isEmpty else { return [] }

        guard warmUp else {
            return try await DelegateDispatch.dispatch(
                tasks, budget: budget,
                worker: { task, _ in try await subagent(task) },
                exhausted: exhausted
            )
        }

        // Warm-up: spend one budget unit to run the first subagent to completion, making the shared
        // model resident before any concurrency starts.
        let granted = await budget.reserve(1)
        guard granted == 1 else { return tasks.map(exhausted) }

        let firstResult = try await subagent(tasks[0])
        let rest = try await DelegateDispatch.dispatch(
            Array(tasks.dropFirst()), budget: budget,
            worker: { task, _ in try await subagent(task) },
            exhausted: exhausted
        )
        return [firstResult] + rest
    }
}
