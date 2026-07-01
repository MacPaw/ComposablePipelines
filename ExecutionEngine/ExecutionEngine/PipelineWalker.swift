//
//  PipelineWalker.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import struct os.OSAllocatedUnfairLock
@_spi(Internals) import PipelineCompiler
import PipelineAST

/// Orchestrates pipeline execution runs.
///
/// The engine is responsible for:
/// - Tracking active runs via `RunRegistry`.
/// - Creating a per-request `ExecutionContext` and `GraphWalker`.
/// - Catching the `EarlyReturn` sentinel at the top level.
/// - Emitting the final `.executionCompleted` event.
///
/// Graph traversal, operation dispatch, and event emission live in `GraphWalker`.
///
/// ```swift
/// let engine = PipelineWalker(executor: MockExecutor())
/// let result = try await engine.run(
///     graph: compiler.compile(pipeline.pipelineGraph),
///     clientActionProvider: PipelineWalker.clientActionProvider(from: [
///         myTask.taskID: { input in ... },
///     ]),
///     initialSlots: [$message.state.id: "Hello"],
///     observingExecution: { event in print(event) }
/// )
/// ```
public final class PipelineWalker {

    /// Wraps a static `taskID` → handler map as ``PipelineWalker/run-swift.method``'s
    /// `clientActionProvider`. Missing keys throw ``ExecutionError/missingClientAction(taskID:)``.
    public static func clientActionProvider(
        from registry: [UUID: @Sendable (ExecutionValue) async throws -> ExecutionValue]
    ) -> @Sendable (UUID, ExecutionValue) async throws -> ExecutionValue {
        { taskID, input in
            guard let action = registry[taskID] else {
                throw ExecutionError.missingClientAction(taskID: taskID)
            }
            return try await action(input)
        }
    }

    // MARK: - State

    private actor RunRegistry {
        private var activeIDs: Set<UUID> = []
        func begin(_ id: UUID) { activeIDs.insert(id) }
        func end(_ id: UUID) { activeIDs.remove(id) }
    }

    // MARK: - Properties

    private let runRegistry = RunRegistry()
    private let executor: any Executor
    private let maxReexecutionDepth: Int
    private let logger: PipelineLog
    private let observer: (any PipelineRunObserver)?

    // MARK: - Init

    public init(
        executor: any Executor,
        maxReexecutionDepth: Int = 200,
        logger: PipelineLog = .none,
        observer: (any PipelineRunObserver)? = nil
    ) {
        self.executor = executor
        self.maxReexecutionDepth = maxReexecutionDepth
        self.logger = logger.subLogger("engine")
        self.observer = observer
    }

    // MARK: - Run

    /// Execute a compiled pipeline graph and return the final value.
    ///
    /// - Parameters:
    ///   - graph: The optimized execution plan produced by `PipelineCompiler`.
    ///   - clientActionProvider: Resolves each `.clientAction` by `taskID` and input bytes.
    ///     Use ``clientActionProvider(from:)`` to adapt a static map, or supply a custom closure
    ///     for remote/IPC dispatch. Omit only when the graph has no client actions.
    ///   - initialSlots: Pre-populated slot values (pipeline inputs, injected context).
    ///   - onCommittedBatch: Invoked after ``ExecutionEvent/stateUpdated`` for each flushed batch:
    ///     one array per **commit** flush (possibly multiple updates) and one array per **draft**
    ///     (typically a single update; inspect ``StateUpdate/kind``). Use for progress or remote
    ///     sync; it is not the graph recompilation hook (``graphProvider`` still runs only after
    ///     commits).
    ///   - graphProvider: Optional hook that returns a replacement graph given only the cursor;
    ///     slot values were already surfaced via events; it runs only after commit flushes.
    ///   - observingExecution: Receives fine-grained `ExecutionEvent` values throughout
    ///     the run. Called on the calling actor's context — keep implementations fast.
    /// - Returns: The value produced by the last node in the graph, or the value from
    ///   a `.returnWith` node if the pipeline exits early.
    public func run(
        graph: PipelineExecutionGraph,
        clientActionProvider: (@Sendable (UUID, ExecutionValue) async throws -> ExecutionValue)? = nil,
        contextProviders: [UUID: any ContextItemsProvider] = [:],
        memoryProvider: (any MemoryProvider)? = nil,
        initialSlots: [UUID: ExecutionValue] = [:],
        onCommittedBatch: (@Sendable ([StateUpdate]) -> Void)? = nil,
        graphProvider: (@Sendable (ExecutionCursor) -> ReexecutionGraph?)? = nil,
        observingExecution eventObserver: (@Sendable (ExecutionEvent) -> Void)? = nil
    ) async throws -> ExecutionValue {
        let runID = UUID()
        await runRegistry.begin(runID)
        let registry = self.runRegistry
        defer { Task { await registry.end(runID) } }

        // `runID` is the OTLP traceId; `rootSpanID` is the `pipeline.run` span that model spans
        // nest under. Bind both (and the observer) so model operations report into this run, and
        // wrap the run so the root observation captures terminal status. No observer → no work.
        let rootSpanID = makePipelineSpanID()
        let telemetryStart = Date()
        do {
            let result = try await TelemetryContext.$observer.withValue(observer) {
                try await TelemetryContext.$runID.withValue(runID) {
                    try await TelemetryContext.$rootSpanID.withValue(rootSpanID) {
                        try await execute(
                            runID: runID,
                            graph: graph,
                            clientActionProvider: clientActionProvider,
                            contextProviders: contextProviders,
                            memoryProvider: memoryProvider,
                            initialSlots: initialSlots,
                            onCommittedBatch: onCommittedBatch,
                            graphProvider: graphProvider,
                            eventObserver: eventObserver
                        )
                    }
                }
            }
            observer?.pipelineRun(runID: runID, spanID: rootSpanID, start: telemetryStart, end: Date(), error: nil)
            return result
        } catch {
            observer?.pipelineRun(runID: runID, spanID: rootSpanID, start: telemetryStart, end: Date(), error: error)
            throw error
        }
    }

    private func execute(
        runID: UUID,
        graph: PipelineExecutionGraph,
        clientActionProvider: (@Sendable (UUID, ExecutionValue) async throws -> ExecutionValue)?,
        contextProviders: [UUID: any ContextItemsProvider],
        memoryProvider: (any MemoryProvider)?,
        initialSlots: [UUID: ExecutionValue],
        onCommittedBatch: (@Sendable ([StateUpdate]) -> Void)?,
        graphProvider: (@Sendable (ExecutionCursor) -> ReexecutionGraph?)?,
        eventObserver: (@Sendable (ExecutionEvent) -> Void)?
    ) async throws -> ExecutionValue {
        let context = ExecutionContext(
            initialSlots: initialSlots,
            clientActionProvider: clientActionProvider,
            onCommittedBatch: onCommittedBatch,
            graphProvider: graphProvider,
            eventObserver: eventObserver,
            contextProviders: contextProviders,
            memoryProvider: memoryProvider
        )
        let walker = GraphWalker(executor: executor, context: context, logger: logger)

        logger.log(.verbose, "execution started")
        let timer = ElapsedTimer()

        var currentGraph = graph
        var depth = 0
        var finalResult: ExecutionValue = Data()

        while true {
            await context.resetWalkOrdinalForIteration()
            let result: ExecutionValue
            do {
                let iteration = depth
                let pendingProgressTasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
                let progress = ExecutionProgressReporter { fraction in
                    // Skip 1.0 — emitted directly below after draining all pending tasks.
                    guard fraction < 1.0 else { return }
                    let task = Task {
                        await context.emit(.resourceProgressUpdated(
                            ExecutionProgressUpdate(
                                runID: runID,
                                iteration: iteration,
                                fraction: fraction
                            )
                        ))
                    }
                    pendingProgressTasks.withLock { $0.append(task) }
                }
                await context.emit(.resourceProgressUpdated(
                    ExecutionProgressUpdate(runID: runID, iteration: iteration, fraction: 0)
                ))
                do {
                    result = try await ExecutionProgressReporter.$current.withValue(progress) {
                        try await walker.walk(currentGraph)
                    }
                    for task in pendingProgressTasks.withLock({ $0 }) { await task.value }
                    await context.emit(.resourceProgressUpdated(
                        ExecutionProgressUpdate(runID: runID, iteration: iteration, fraction: 1.0)
                    ))
                } catch {
                    for task in pendingProgressTasks.withLock({ $0 }) { await task.value }
                    await context.emit(.resourceProgressUpdated(
                        ExecutionProgressUpdate(runID: runID, iteration: iteration, fraction: 1.0)
                    ))
                    throw error
                }
            } catch let earlyReturn as EarlyReturn {
                logger.log(.verbose, "pipeline-run - \(timer.nanoseconds().prettyDuration)")
                await context.emit(.executionCompleted)
                return earlyReturn.value
            }

            // Pipeline contract: the prefix is stable across re-emissions, so the new graph
            // must yield at least `activeSkipTaskCount` surface ordinals. A shorter graph
            // means the recompiled prefix dropped already-executed work — pathological.
            let allocated = await context.walkOrdinalsAllocated()
            let activeSkip = await context.activeSkipTaskCount()
            if allocated < activeSkip {
                throw ExecutionError.prefixShorterThanRecordedSkipCount(
                    expectedSkipCount: activeSkip,
                    actualGraphTaskCount: allocated
                )
            }

            // Carry `finalResult` from the previous pass when this pass produced no new
            // surface work — an all-skipped pass means the graph hasn't progressed beyond
            // what we already returned, so the prior final value is still authoritative.
            let surfaceWork = await context.surfaceTaskExecuteCount()
            if surfaceWork > 0 {
                finalResult = result
            }

            guard let nextGraph = await context.consumeReexecution(),
                  depth < maxReexecutionDepth else {
                if depth >= maxReexecutionDepth {
                    logger.log(.warning, "max re-execution depth reached (\(maxReexecutionDepth))")
                }
                break
            }

            // No flattened-suffix structural check here: `graphProvider` may recompile different
            // control-flow remainders after slot commits. Prefix skip is offset-only — slot
            // values persist across iterations, and a shrunk prefix is caught by the guard above.

            depth += 1
            await context.emit(.reexecutionStarted(depth: depth))
            walker.stepVerboseLogger.log(.verbose, "╌╌ ↻ re-evaluation #\(depth) ╌╌")
            currentGraph = nextGraph.graph
            await context.beginNewIteration()
        }

        logger.log(.verbose, "pipeline-run - \(timer.nanoseconds().prettyDuration)")
        await context.emit(.executionCompleted)
        return finalResult
    }
}
