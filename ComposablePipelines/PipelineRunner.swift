//
//  PipelineRunner.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST
import PipelineCompiler
@_spi(Internals) import PipelineDSL
import ExecutionEngine

/// Drives a `Pipeline` through the full lower → compile → walk path with **reactive re-lowering**,
/// so `While` loops and value-dependent control flow re-read committed state on every iteration.
///
/// A single `PipelineWalker.run` is enough for linear flow, `ForEach`, and runtime `.get()` reads.
/// Anything that branches or loops on a *produced* value (a `While` whose condition reads a model
/// reply, an `if`/`switch` over model output) needs this driver: it re-lowers and recompiles after
/// every commit batch, feeds committed slot values back into a persistent DSL `ExecutionContext`,
/// and hands the engine a cursor-trimmed graph so already-executed surface tasks are not repeated.
///
/// `ClientTask` closures are captured at lowering and run as written; only `Model`/`Guardrail`
/// steps consult the `executor`.
public enum PipelineRunner {

    /// Run `pipeline` to completion, returning its final output value.
    /// - Parameters:
    ///   - executor: backs `Model`/`Guardrail` steps.
    ///   - initialSlots: seed values for `@State` slots, keyed by slot id.
    ///   - maxReexecutionDepth: hard cap on loop/re-execution iterations (matches the walker default).
    ///   - observingExecution: receives every `ExecutionEvent` as the walk progresses.
    public static func run<P: Pipeline>(
        _ pipeline: P,
        executor: any Executor,
        initialSlots: [UUID: ExecutionValue] = [:],
        maxReexecutionDepth: Int = 200,
        optimizations: PipelineCompiler.Optimizations = .default,
        observingExecution: (@Sendable (ExecutionEvent) -> Void)? = nil
    ) async throws -> ExecutionValue {
        let compiler = PipelineCompiler(optimizations: optimizations)
        let engine = PipelineWalker(executor: executor, maxReexecutionDepth: maxReexecutionDepth)
        let dsl = ExecutionContext()
        let registry = ActionRegistry()
        let pending = PendingCommits()

        // Re-lower against the persistent DSL context so `While`/`if` re-read committed slot
        // values; recompile to a fresh execution graph.
        func lowerNow() -> (graph: PipelineExecutionGraph, actions: [UUID: PipelineClientAction]) {
            ExecutionContext.$current.withValue(dsl) {
                ExecutionContext.$executionEpoch.withValue(dsl.committedEpoch) {
                    let lowered = pipeline.loweredGraphWithClientActions()
                    return (compiler.compile(lowered.graph), lowered.clientActions)
                }
            }
        }

        let first = lowerNow()
        registry.merge(first.actions)

        // Commit batches are buffered, then applied to the DSL context inside the graphProvider
        // right before re-lowering — so the re-lowered condition/branches see exactly the committed
        // slot values, and the engine's prefix-skip is replaced by our cursor-trimmed graph.
        return try await engine.run(
            graph: first.graph,
            clientActionProvider: { id, input in
                if let action = registry.action(for: id) { return try await action(input) }
                throw ExecutionError.missingClientAction(taskID: id)
            },
            initialSlots: initialSlots,
            onCommittedBatch: { batch in
                let commits = batch.filter { $0.kind == .commit }
                if !commits.isEmpty { pending.append(commits) }
            },
            graphProvider: { cursor in
                let commits = pending.take()
                if !commits.isEmpty {
                    dsl.applyStateUpdatesFromRemote(
                        commits.map { (slotID: $0.slotID, epoch: $0.epoch, value: $0.value, kind: $0.kind) }
                    )
                }
                let next = lowerNow()
                registry.merge(next.actions)
                let appliedOffset = Swift.max(0, Swift.min(cursor.offset, next.graph.surfaceTaskCount()))
                return ReexecutionGraph(
                    graph: next.graph.droppingFirstSurfaceTasks(appliedOffset),
                    appliedCursor: ExecutionCursor(epoch: cursor.epoch, offset: appliedOffset)
                )
            },
            observingExecution: observingExecution
        )
    }

    // MARK: - Collaborators

    /// Buffers commit batches between flushes (drained inside the graphProvider).
    private final class PendingCommits: @unchecked Sendable {
        private let lock = NSLock()
        private var commits: [StateUpdate] = []

        func append(_ new: [StateUpdate]) {
            lock.lock(); commits.append(contentsOf: new); lock.unlock()
        }

        func take() -> [StateUpdate] {
            lock.lock(); defer { commits.removeAll(); lock.unlock() }
            return commits
        }
    }

    /// Accumulates client-action closures across re-lowerings (taskIDs may change per pass).
    private final class ActionRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [UUID: PipelineClientAction] = [:]

        func merge(_ new: [UUID: PipelineClientAction]) {
            lock.lock(); actions.merge(new) { _, latest in latest }; lock.unlock()
        }

        func action(for id: UUID) -> PipelineClientAction? {
            lock.lock(); defer { lock.unlock() }
            return actions[id]
        }
    }
}
