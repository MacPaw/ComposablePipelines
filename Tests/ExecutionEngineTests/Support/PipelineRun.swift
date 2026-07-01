//
//  PipelineRun.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineCompiler
@_spi(Internals) import PipelineDSL
@testable import ExecutionEngine

/// Drives a `Pipeline` through the real lower → compile → walk path with a scripted
/// ``Executor``, capturing every ``ExecutionEvent`` for assertions.
///
/// Two entry points:
/// - ``runOnce(_:executor:initialSlots:optimizations:)`` compiles the lowered graph a single
///   time. Correct when control flow does not depend on *produced* values — linear flow,
///   `ForEach`, runtime `.get()` reads, retrieval.
/// - ``runReactive(_:executor:initialSlots:clientActionResolver:maxReexecutionDepth:optimizations:)``
///   mirrors a reactive host client: it re-lowers + recompiles after every commit and feeds committed
///   slot values back into a persistent DSL `ExecutionContext`. Required for `While` loops and
///   `if`/`switch` that branch on model output.
///
/// `ClientTask` closures are captured at lowering and run as written; only `Model`/`Guardrail`
/// steps consult the scripted executor.
enum PipelineRun {

    typealias Trace = (result: ExecutionValue, events: [ExecutionEvent])

    // MARK: - Single pass

    static func runOnce<P: Pipeline>(
        _ pipeline: P,
        executor: any Executor,
        initialSlots: [UUID: ExecutionValue] = [:],
        optimizations: PipelineCompiler.Optimizations = [.parallelize]
    ) async throws -> Trace {
        let lowered = pipeline.lowered()
        let graph = PipelineCompiler(optimizations: optimizations).compile(lowered.graph)
        let engine = PipelineWalker(executor: executor)
        let sink = EventSink()

        let result = try await engine.run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions),
            contextProviders: lowered.contextProviders,
            initialSlots: initialSlots,
            observingExecution: { sink.append($0) }
        )
        return (result, sink.snapshot())
    }

    // MARK: - Reactive (re-lowering) loop

    static func runReactive<P: Pipeline>(
        _ pipeline: P,
        executor: any Executor,
        initialSlots: [UUID: ExecutionValue] = [:],
        clientActionResolver: (@Sendable (UUID, ExecutionValue) async throws -> ExecutionValue)? = nil,
        maxReexecutionDepth: Int = 200,
        optimizations: PipelineCompiler.Optimizations = [.parallelize]
    ) async throws -> Trace {
        let compiler = PipelineCompiler(optimizations: optimizations)
        let engine = PipelineWalker(executor: executor, maxReexecutionDepth: maxReexecutionDepth)
        let dsl = PipelineDSL.ExecutionContext()
        let registry = ActionRegistry()
        let pending = PendingCommits()

        // Re-lower against the persistent DSL context so `While`/`if` re-read committed slot
        // values; recompile to a fresh execution graph.
        func lowerNow() -> (graph: PipelineExecutionGraph, actions: [UUID: PipelineClientAction]) {
            PipelineDSL.ExecutionContext.$current.withValue(dsl) {
                PipelineDSL.ExecutionContext.$executionEpoch.withValue(dsl.committedEpoch) {
                    let lowered = pipeline.loweredGraphWithClientActions()
                    return (compiler.compile(lowered.graph), lowered.clientActions)
                }
            }
        }

        let first = lowerNow()
        registry.merge(first.actions)
        let sink = EventSink()

        // Mirror a reactive host client: commit batches are buffered via `onCommittedBatch`, then
        // applied to the DSL context *inside* the graphProvider right before re-lowering — so the
        // re-lowered condition/branches see exactly the committed slot values, and the engine's
        // own prefix-skip is disabled (we hand back a cursor-trimmed graph).
        let result = try await engine.run(
            graph: first.graph,
            clientActionProvider: { id, input in
                if let action = registry.action(for: id) { return try await action(input) }
                if let resolver = clientActionResolver { return try await resolver(id, input) }
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
            observingExecution: { sink.append($0) }
        )
        return (result, sink.snapshot())
    }

    // MARK: - Collaborators

    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ExecutionEvent] = []

        func append(_ event: ExecutionEvent) {
            lock.lock(); events.append(event); lock.unlock()
        }

        func snapshot() -> [ExecutionEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    /// Buffers commit batches between flushes (drained inside the graphProvider, like a host client).
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

// MARK: - Event queries

extension Array where Element == ExecutionEvent {

    /// `operationLabel`s of every completed step, in completion order
    /// (e.g. `["guardrail", "model", "stateSet", …]`).
    func completedOperations() -> [String] {
        compactMap { event in
            if case .stepCompleted(let info, _, _) = event { return info.operationLabel }
            return nil
        }
    }

    /// Every value written to `slotID`, in write order — the slot's history across the run.
    func slotHistory(_ slotID: UUID) -> [ExecutionValue] {
        compactMap { event in
            if case .stateUpdated(let update) = event, update.slotID == slotID { return update.value }
            return nil
        }
    }

    /// Decoded history of a `String` slot.
    func slotHistoryStrings(_ slotID: UUID) -> [String] {
        slotHistory(slotID).map { (try? JSONDecoder().decode(String.self, from: $0)) ?? "<non-string>" }
    }

    /// Last value written to `slotID`, if any.
    func lastValue(forSlot slotID: UUID) -> ExecutionValue? {
        slotHistory(slotID).last
    }

    /// Index of the first completed step whose `operationLabel` equals `label`.
    func firstCompletedIndex(of label: String) -> Int? {
        firstIndex { event in
            if case .stepCompleted(let info, _, _) = event { return info.operationLabel == label }
            return false
        }
    }

    /// Index of the first `stateUpdated` for `slotID`.
    func firstStateUpdateIndex(forSlot slotID: UUID) -> Int? {
        firstIndex { event in
            if case .stateUpdated(let update) = event { return update.slotID == slotID }
            return false
        }
    }

    /// Count of completed steps with the given `operationLabel`.
    func completedCount(of label: String) -> Int {
        completedOperations().filter { $0 == label }.count
    }
}
