//
//  ExecutionContext.swift
//  elix-toolchain
//
//  Created by Oleksandr Frankiv on 20.04.2026.
//

import Foundation
import PipelineAST
import PipelineCompiler

/// Result wrapper for the cursor-only ``graphProvider`` recompilation hook.
public struct ReexecutionGraph: Sendable {
    public let graph: PipelineExecutionGraph
    /// Non-nil when `graph` already had `appliedCursor.offset` surface tasks dropped.
    public let appliedCursor: ExecutionCursor?

    public init(graph: PipelineExecutionGraph, appliedCursor: ExecutionCursor? = nil) {
        self.graph = graph
        self.appliedCursor = appliedCursor
    }
}

/// Per-request execution state: slot storage, trace, event reporting, epoch-tagged
/// state updates, and ordinal-keyed prefix skip (offset only — slots carry forward
/// values across iterations, so no per-task value memo is needed).
///
/// A fresh `ExecutionContext` is created for every `PipelineWalker.run(...)` call.
actor ExecutionContext {

    // MARK: - Mutable State

    private var slots: [UUID: ExecutionValue]
    private(set) var trace: [TraceEntry] = []
    private var traceIndex: [UUID: Int] = [:]

    // MARK: - Parallel Batching (commits only)

    /// Writes awaiting flush after `.parallel` branches join. Only **commit** kinds are queued;
    /// **draft** writes notify observers immediately via ``emitDraftNotification`` (live previews,
    /// parallel streaming) and never invoke ``graphProvider``.
    private var parallelDepth = 0
    private var pendingCommitWrites: [(
        slotID: UUID,
        valueTypeName: String,
        debugLabel: String?,
        previousValue: ExecutionValue?,
        value: ExecutionValue
    )] = []

    // MARK: - Epoch (one increment per committed slot write)

    private var nextEpoch: ExecutionEpoch = 1

    // MARK: - Prefix skip (re-execution)

    /// Branch-major DFS surface-task ordinal counter. Drives the offset-only prefix skip:
    /// ``shouldSkipWalkTask`` compares against ``activeSkipCount`` (= ``walkTaskOrdinal``
    /// at the moment the previous walk scheduled re-execution).
    private var walkTaskOrdinal: Int = 0
    private var activeSkipCount: Int = 0
    private var pendingSkipCountForNextWalk: Int = 0

    /// Surface tasks that actually ran (non-skipped) during the current walk iteration.
    /// Used by ``PipelineWalker`` to decide whether to overwrite `finalResult` after a pass.
    private var surfaceTaskExecuteCountInIteration: Int = 0

    /// Skip count recorded when scheduling the next graph (for structural suffix validation).
    func pendingSkipTaskCount() -> Int {
        pendingSkipCountForNextWalk
    }

    /// Number of surface (top-level) tasks that ran in the current walk iteration. Zero means
    /// the entire pass was prefix-skipped — the engine keeps the prior pass's final value.
    func surfaceTaskExecuteCount() -> Int {
        surfaceTaskExecuteCountInIteration
    }

    /// Total surface ordinals reserved during the current walk (count of surface tasks the
    /// walker encountered, including skipped ones). Used by the engine to detect a graph
    /// shorter than the recorded skip prefix.
    func walkOrdinalsAllocated() -> Int {
        walkTaskOrdinal
    }

    /// Skip count active for the current walk (surface tasks the walker treated as already
    /// completed in a prior pass).
    func activeSkipTaskCount() -> Int {
        activeSkipCount
    }

    // MARK: - Walker verbose pretty printing

    private var walkerStepCounter = 0
    private var walkerParallelLogDepth = 0
    private var walkerParallelBufferStack: [[[String]]] = []

    // MARK: - Re-execution

    private(set) var needsReexecution = false
    private var scheduledGraph: ReexecutionGraph?

    // MARK: - Immutable Per-run Configuration

    private let clientActionProvider: (@Sendable (UUID, ExecutionValue) async throws -> ExecutionValue)?
    /// After each ``ExecutionEvent/stateUpdated`` flush: **commit** batches from parallel joins
    /// (multi-update arrays), and **draft** batches as a single update each (``StateUpdate/kind``
    /// is ``StateWriteKind/draft``). Use for progress / remote mirroring; this is **not** the
    /// graph-recompile hook — ``graphProvider`` runs only after commit flushes.
    private let onCommittedBatch: (@Sendable ([StateUpdate]) -> Void)?
    /// Invoked only after a **commit** flush (after ``onCommittedBatch`` with commit updates) to
    /// optionally supply a replacement graph. Receives only ``ExecutionCursor`` — slot payloads
    /// were already delivered via ``ExecutionEvent/stateUpdated`` and ``onCommittedBatch``.
    /// If `appliedCursor` is non-nil, the returned graph is assumed to be trimmed to that cursor
    /// and the engine will not apply its own offset skip for the returned pass.
    private let graphProvider: (@Sendable (ExecutionCursor) -> ReexecutionGraph?)?
    private let eventObserver: (@Sendable (ExecutionEvent) -> Void)?
    private let contextProviders: [UUID: any ContextItemsProvider]

    // MARK: - Init

    init(
        initialSlots: [UUID: ExecutionValue] = [:],
        clientActionProvider: (@Sendable (UUID, ExecutionValue) async throws -> ExecutionValue)? = nil,
        onCommittedBatch: (@Sendable ([StateUpdate]) -> Void)? = nil,
        graphProvider: (@Sendable (ExecutionCursor) -> ReexecutionGraph?)? = nil,
        eventObserver: (@Sendable (ExecutionEvent) -> Void)? = nil,
        contextProviders: [UUID: any ContextItemsProvider] = [:]
    ) {
        self.slots = initialSlots
        self.clientActionProvider = clientActionProvider
        self.onCommittedBatch = onCommittedBatch
        self.contextProviders = contextProviders
        self.graphProvider = graphProvider
        self.eventObserver = eventObserver
    }

    // MARK: - Slot Access

    func getSlot(_ id: UUID) -> ExecutionValue? {
        slots[id]
    }

    func setSlot(_ id: UUID, value: ExecutionValue) {
        slots[id] = value
    }

    // MARK: - Prefix skip API (GraphWalker)

    func resetWalkOrdinalForIteration() {
        walkTaskOrdinal = 0
        surfaceTaskExecuteCountInIteration = 0
    }

    func takeWalkOrdinal() -> Int {
        let o = walkTaskOrdinal
        walkTaskOrdinal += 1
        return o
    }

    /// Reserves ``count`` contiguous ordinals for a `.parallel` subtree so concurrent branches can
    /// assign ``takeWalkOrdinal()``-compatible indices in **branch-major DFS order** without racing
    /// on ``walkTaskOrdinal`` (see ``GraphWalker``).
    func reserveWalkOrdinalBlock(count: Int) -> Int {
        let start = walkTaskOrdinal
        walkTaskOrdinal += count
        return start
    }

    func shouldSkipWalkTask(ordinal: Int) -> Bool {
        ordinal < activeSkipCount
    }

    /// Bump the per-iteration counter for surface tasks that actually executed (i.e. were not
    /// prefix-skipped). The engine uses this to decide whether the pass produced new work.
    func recordSurfaceTaskExecuted() {
        surfaceTaskExecuteCountInIteration += 1
    }

    func setActiveSkipCount(_ count: Int) {
        activeSkipCount = count
    }

    // MARK: - State Updates

    func recordStateWrite(
        slotID: UUID,
        valueTypeName: String,
        debugLabel: String?,
        previousValue: ExecutionValue?,
        value: ExecutionValue,
        kind: StateWriteKind = .commit
    ) {
        switch kind {
        case .draft:
            emitDraftNotification(
                slotID: slotID,
                valueTypeName: valueTypeName,
                debugLabel: debugLabel,
                previousValue: previousValue,
                value: value
            )
        case .commit:
            pendingCommitWrites.append(
                (slotID, valueTypeName, debugLabel, previousValue, value)
            )
            if parallelDepth == 0 {
                flushCommittedStateUpdates()
            }
        }
    }

    /// Draft slot changes: notify observers immediately (including during `.parallel`) without
    /// batching or calling ``graphProvider``.
    private func emitDraftNotification(
        slotID: UUID,
        valueTypeName: String,
        debugLabel: String?,
        previousValue: ExecutionValue?,
        value: ExecutionValue
    ) {
        let update = StateUpdate(
            slotID: slotID,
            valueTypeName: valueTypeName,
            debugLabel: debugLabel,
            previousValue: previousValue,
            value: value,
            epoch: 0,
            kind: .draft
        )
        eventObserver?(.stateUpdated(update))
        onCommittedBatch?([update])
    }

    func enterParallel() {
        parallelDepth += 1
    }

    func exitParallel() {
        parallelDepth -= 1
        if parallelDepth == 0 {
            flushCommittedStateUpdates()
        }
    }

    /// Flushes pending **commit** writes: emits events, then optionally invokes ``graphProvider``
    /// for re-execution. Commits stay batched until parallel outermost depth returns to zero.
    private func flushCommittedStateUpdates() {
        guard !pendingCommitWrites.isEmpty else { return }
        let sorted = pendingCommitWrites.sorted {
            $0.slotID.uuidString < $1.slotID.uuidString
        }
        pendingCommitWrites.removeAll()

        var batch: [StateUpdate] = []
        for write in sorted {
            let epoch = nextEpoch
            nextEpoch += 1
            batch.append(
                StateUpdate(
                    slotID: write.slotID,
                    valueTypeName: write.valueTypeName,
                    debugLabel: write.debugLabel,
                    previousValue: write.previousValue,
                    value: write.value,
                    epoch: epoch,
                    kind: .commit
                )
            )
        }
        for update in batch {
            eventObserver?(.stateUpdated(update))
        }
        onCommittedBatch?(batch)
        let cursor = ExecutionCursor(epoch: nextEpoch - 1, offset: walkTaskOrdinal)
        // Always ask `graphProvider` for the latest suffix, even when `needsReexecution` is already
        // true: a single walk can flush **multiple** commit batches (nested `stateSet` → inner work
        // commits, then the outer walk continues). The first batch schedules re-execution with a
        // cursor offset that only accounts for work committed **so far**; a later batch in the
        // **same** walk must supersede `scheduledGraph` with a larger offset. Skipping the second
        // `graphProvider` call left stale trim (e.g. only `$conversation` dropped) so the next pass
        // still replayed `Model` and never reached a following `ClientTask` in the same `While` body.
        guard let provided = graphProvider?(cursor) else { return }
        // Must match how many surface ordinals have been allocated this walk (including reserved
        // `.parallel` blocks); concurrent branches may finalize out of order and a simple count
        // of completed tasks can lag behind the highest reserved ordinal + 1.
        pendingSkipCountForNextWalk = (provided.appliedCursor == nil) ? walkTaskOrdinal : 0
        scheduledGraph = provided
        needsReexecution = true
    }

    // MARK: - Re-execution Control

    func consumeReexecution() -> ReexecutionGraph? {
        guard needsReexecution, let graph = scheduledGraph else { return nil }
        needsReexecution = false
        scheduledGraph = nil
        return graph
    }

    func beginNewIteration() {
        pendingCommitWrites.removeAll()
        parallelDepth = 0
        walkerParallelLogDepth = 0
        walkerParallelBufferStack.removeAll()
        activeSkipCount = pendingSkipCountForNextWalk
        pendingSkipCountForNextWalk = 0
        walkTaskOrdinal = 0
    }

    func walkerBuffersExecuteLines() -> Bool {
        walkerParallelLogDepth > 0
    }

    func walkerEnterParallelGroup(branchCount: Int) {
        walkerParallelLogDepth += 1
        walkerParallelBufferStack.append(Array(repeating: [], count: max(0, branchCount)))
    }

    func walkerAppendBufferedExecuteLine(branchIndex: Int, lineBodyWithoutStepNumber: String) {
        guard let top = walkerParallelBufferStack.last else { return }
        guard branchIndex >= 0, branchIndex < top.count else { return }
        walkerParallelBufferStack[walkerParallelBufferStack.count - 1][branchIndex].append(lineBodyWithoutStepNumber)
    }

    func walkerLeaveParallelGroup() -> ParallelPrettyLogBundle? {
        guard walkerParallelLogDepth > 0, let buffers = walkerParallelBufferStack.popLast() else { return nil }
        walkerParallelLogDepth -= 1
        let merged = buffers.indices.flatMap { buffers[$0] }
        var numbered: [String] = []
        for raw in merged {
            walkerStepCounter += 1
            numbered.append("\(walkerStepCounter). \(raw)")
        }
        let executed = numbered.count
        return ParallelPrettyLogBundle(numberedLines: numbered, executedCount: executed)
    }

    func walkerFormatSequentialExecuteLine(_ lineBodyWithoutStepNumber: String) -> String {
        walkerStepCounter += 1
        return "\(walkerStepCounter). \(lineBodyWithoutStepNumber)"
    }

    func walkerAbandonParallelLogging() {
        walkerParallelLogDepth = 0
        walkerParallelBufferStack.removeAll()
    }

    var traceCount: Int { trace.count }

    func emit(_ event: ExecutionEvent) {
        eventObserver?(event)
    }

    // MARK: - Client Actions

    func executeClientAction(taskID: UUID, input: ExecutionValue) async throws -> ExecutionValue {
        try await ClientActionDraftSlotHooks.withPublishHandler({ slotID, value, valueTypeName in
            await self.applyDraftSlotWrite(slotID: slotID, valueTypeName: valueTypeName, value: value)
        }) {
            guard let clientActionProvider else {
                throw ExecutionError.missingClientAction(taskID: taskID)
            }
            return try await clientActionProvider(taskID, input)
        }
    }

    /// Draft updates from long-running client actions (e.g. streamed HTTP); does not advance epoch or invoke `graphProvider`.
    private func applyDraftSlotWrite(slotID: UUID, valueTypeName: String, value: ExecutionValue) {
        let previousValue = getSlot(slotID)
        setSlot(slotID, value: value)
        guard previousValue != value else { return }
        recordStateWrite(
            slotID: slotID,
            valueTypeName: valueTypeName,
            debugLabel: nil,
            previousValue: previousValue,
            value: value,
            kind: .draft
        )
    }

    // MARK: - Context items

    func executeContextProvide(providerID: UUID, query: String) async throws -> [ContextItem] {
        guard let provider = contextProviders[providerID] else {
            throw ExecutionError.missingContextProvider(providerID: providerID)
        }
        return try await provider.fetch(query: query)
    }

    // MARK: - Trace

    func record(_ entry: TraceEntry) {
        traceIndex[entry.taskID] = trace.count
        trace.append(entry)
    }
}

/// Numbered execute lines for one finished `.parallel` group (tree-style pretty printing).
struct ParallelPrettyLogBundle: Sendable {
    let numberedLines: [String]
    let executedCount: Int
}

// MARK: - TraceEntry

extension ExecutionContext {
    struct TraceEntry {
        let taskID: UUID
        let operationLabel: String
        let startedAt: Date
        var durationNanoseconds: UInt64?
        var failed: Bool

        init(taskID: UUID, operationLabel: String, startedAt: Date) {
            self.taskID = taskID
            self.operationLabel = operationLabel
            self.startedAt = startedAt
            self.durationNanoseconds = nil
            self.failed = false
        }
    }

    func finishTraceEntry(taskID: UUID, durationNanoseconds: UInt64, failed: Bool) {
        guard let idx = traceIndex[taskID] else { return }
        trace[idx].durationNanoseconds = durationNanoseconds
        trace[idx].failed = failed
    }
}
