//
//  GraphWalker.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST
@_spi(Internals) import PipelineCompiler

/// Re-runs the enclosing **root** graph for one self-delegate subagent: seeds `seed` into
/// `taskInputSlotID`, grants the shared spawn `budget` and the `capabilities` the parent opted into,
/// and returns the delegate's final value. Built by `PipelineWalker.run` (which captures the root graph),
/// so the walker never stores the graph itself.
///
/// `pathPrefix` is the subagent's ``DelegateRunID`` path from the delegate root (so nested delegate
/// events carry a full hierarchical path), and `observer` forwards the child run's `.delegateSubagent`
/// events up to the parent run so observation reaches arbitrary recursion depth.
///
/// - Author: Claude
typealias SelfDelegateRunner = @Sendable (
    _ seed: ExecutionValue,
    _ taskInputSlotID: UUID,
    _ capabilities: InheritedCapabilities,
    _ budget: SpawnBudget,
    _ pathPrefix: [Int],
    _ observer: (@Sendable (ExecutionEvent) -> Void)?
) async throws -> ExecutionValue

/// Recursively traverses a `PipelineExecutionGraph` and executes each node.
///
/// A fresh `GraphWalker` is created per `PipelineWalker.run(...)` call; it holds
/// the per-request `ExecutionContext` and the `Executor` it dispatches model work to.
/// The walker knows nothing about resources or model backends.
///
/// The walker is a value type: capturing it in task-group or `async let` closures
/// is safe because its state lives entirely in the actor-isolated `context`.
struct GraphWalker: Sendable {

    // MARK: - Properties

    private let executor: any Executor
    private let context: ExecutionContext
    private let logger: PipelineLog
    /// Capability to re-run the enclosing **root** graph for a self-delegate subagent — supplied by
    /// `PipelineWalker.run` (it captures the root there, so the walker never *holds* the graph). `nil`
    /// only if the walker was built without self-delegate support; then a `.selfRecursion` leaf throws.
    private let selfDelegate: SelfDelegateRunner?
    /// The shared spawn budget for the self-tree this walker belongs to, threaded down so a nested
    /// `.selfRecursion` reuses it (`nil` at the top — the first self-delegate leaf creates it).
    private let selfDelegateBudget: SpawnBudget?
    /// This walker's ``DelegateRunID`` path from the delegate root (`[]` at the top). A `.delegate` leaf
    /// stamps `delegatePathPrefix + [childIndex]` onto every subagent event, so a snapshot fold sees a
    /// full hierarchical path even for subagents nested many recursion levels deep.
    private let delegatePathPrefix: [Int]

    /// Same logger used for numbered step / parallel tree lines (`…engine.walker` under the engine).
    var stepVerboseLogger: PipelineLog { logger }

    // MARK: - Init

    init(
        executor: any Executor,
        context: ExecutionContext,
        logger: PipelineLog = .none,
        selfDelegate: SelfDelegateRunner? = nil,
        selfDelegateBudget: SpawnBudget? = nil,
        delegatePathPrefix: [Int] = []
    ) {
        self.executor = executor
        self.context = context
        self.logger = logger.subLogger("walker")
        self.selfDelegate = selfDelegate
        self.selfDelegateBudget = selfDelegateBudget
        self.delegatePathPrefix = delegatePathPrefix
    }

    // MARK: - Walk

    /// Recursively evaluate a graph node and return its result value.
    ///
    /// `EarlyReturn` propagates untouched through every recursive call and is
    /// caught only at the `PipelineWalker.run(...)` entry point.
    func walk(_ graph: PipelineExecutionGraph) async throws -> ExecutionValue {
        // Bound once here rather than at each model call: the path is ambient to everything this walker
        // does, and a subagent gets its own walker. Executors read it to attribute per-call cost without
        // the path having to appear in `Executor`'s signature.
        try await TelemetryContext.$delegatePath.withValue(delegatePathPrefix) {
            let (value, _) = try await walkCountingNonSkippedTasks(graph, logCountedSteps: true)
            return value
        }
    }

    /// Returns `(result, nonSkippedTaskCount)` where `nonSkippedTaskCount` is the number of
    /// `.task` nodes that ran a full execute path (not memo `.stepSkipped`) in this subtree.
    /// Used for accurate `parallelGroupCompleted(executed:)` under concurrent branches.
    ///
    /// When `logCountedSteps` is `false` (value subgraph of a `stateSet`), nested `.task`
    /// verbose lines are suppressed so only the outer `[slot].set` line appears (one line
    /// per top-level task).
    private func walkCountingNonSkippedTasks(
        _ graph: PipelineExecutionGraph,
        parallelBranchIndex: Int? = nil,
        logCountedSteps: Bool = true
    ) async throws -> (ExecutionValue, Int) {
        switch graph {

        case .empty:
            return (Data(), 0)

        case .sequential(let steps):
            var result = Data()
            var executed = 0
            for step in steps {
                let (r, n) = try await walkCountingNonSkippedTasks(
                    step,
                    parallelBranchIndex: parallelBranchIndex,
                    logCountedSteps: logCountedSteps
                )
                result = r
                executed += n
                // If graphProvider scheduled a re-evaluation mid-pass, abort the
                // remainder of this walk. Steps executed so far are already memoised;
                // the next pass will pick up from the correct graph without re-running them.
                if await context.needsReexecution { break }
            }
            return (result, executed)

        case .parallel(let branches):
            // Independent branches — no shared slot dependencies — run concurrently.
            // Slot writes are batched until all branches finish; exitParallel() flushes
            // them as individual .stateUpdated events after .parallelGroupCompleted.
            await context.emit(.parallelGroupStarted(count: branches.count))
            await context.enterParallel()
            await context.walkerEnterParallelGroup(branchCount: branches.count)
            var branchesWithWork = 0
            var totalNonSkipped = 0
            var branchResults = Array<ExecutionValue?>(repeating: nil, count: branches.count)
            do {
                try await withThrowingTaskGroup(of: (Int, ExecutionValue, Int, Int).self) { group in
                    for (idx, branch) in branches.enumerated() {
                        group.addTask {
                            let (value, n) = try await self.walkCountingNonSkippedTasks(
                                branch,
                                parallelBranchIndex: idx,
                                logCountedSteps: logCountedSteps
                            )
                            // `parallelGroupCompleted.executed`: branches that did any non-skipped work
                            // (per-branch "had executes" intent).
                            let branchHadWork = n > 0 ? 1 : 0
                            return (idx, value, n, branchHadWork)
                        }
                    }
                    for try await (idx, value, n, branchHadWork) in group {
                        branchResults[idx] = value
                        totalNonSkipped += n
                        branchesWithWork += branchHadWork
                    }
                }
            } catch {
                await context.walkerAbandonParallelLogging()
                await context.exitParallel()
                throw error
            }
            if let bundle = await context.walkerLeaveParallelGroup() {
                flushParallelPrettyLog(bundle)
            }
            await context.emit(.parallelGroupCompleted(count: branches.count, executed: branchesWithWork))
            await context.exitParallel()
            return (branchResults.reversed().compactMap { $0 }.first ?? Data(), totalNonSkipped)

        case .returnWith(let inner):
            let (value, _) = try await walkCountingNonSkippedTasks(
                inner,
                parallelBranchIndex: parallelBranchIndex,
                logCountedSteps: logCountedSteps
            )
            throw EarlyReturn(value: value)

        case .task(let task):
            return try await executeTaskCounting(
                task,
                parallelBranchIndex: parallelBranchIndex,
                logCountedSteps: logCountedSteps
            )

        case .loopScope(let body):
            // One reactive-loop iteration: commits batch until the body finishes, then flush once
            // (scheduling the next pass). Contained tasks bypass prefix-skip, so the body re-runs
            // afresh each iteration until the re-lowered body is empty (condition false).
            await context.enterLoopScope()
            do {
                let result = try await walkCountingNonSkippedTasks(
                    body,
                    parallelBranchIndex: parallelBranchIndex,
                    logCountedSteps: logCountedSteps
                )
                await context.exitLoopScope()
                return result
            } catch {
                await context.exitLoopScope()
                throw error
            }

        case let .branch(conditionSlotID, then, otherwise):
            // Slot-driven, evaluated in-graph: pick the branch from the committed Bool. No re-lowering,
            // so this works inside a delegate's static walk (no `graphProvider`).
            let taken = await readConditionBool(conditionSlotID) ? then : otherwise
            return try await walkCountingNonSkippedTasks(
                taken, parallelBranchIndex: parallelBranchIndex, logCountedSteps: logCountedSteps)

        case let .whileLoop(conditionSlotID, body):
            // Slot-driven, iterated in-graph: while the committed Bool is true, walk the body (which
            // must update the slot). A loop scope batches the body's commits so a mid-loop commit
            // doesn't schedule re-execution; the slot value is still visible immediately for the next
            // condition read. No re-lowering — works inside a delegate's static walk.
            await context.enterLoopScope()
            let outcome: Result<(ExecutionValue, Int), any Error>
            do {
                var result: ExecutionValue = Data()
                var executed = 0
                var iterations = 0
                while await readConditionBool(conditionSlotID) {
                    iterations += 1
                    guard iterations <= Self.maxInGraphLoopIterations else {
                        throw ExecutionError.inGraphLoopExceededMaxIterations(Self.maxInGraphLoopIterations)
                    }
                    let (value, nonSkipped) = try await walkCountingNonSkippedTasks(
                        body, parallelBranchIndex: parallelBranchIndex, logCountedSteps: logCountedSteps)
                    result = value
                    executed += nonSkipped
                }
                outcome = .success((result, executed))
            } catch {
                outcome = .failure(error)
            }
            await context.exitLoopScope()
            return try outcome.get()
        }
    }

    /// Upper bound on in-graph `whileLoop` iterations — a safety net against a body that never falsifies
    /// its condition slot (the analogue of the re-execution depth cap).
    static let maxInGraphLoopIterations = 1000

    /// Read a `Bool` condition slot for `.branch` / `.whileLoop`. Reads as `false` (ends a loop / takes the
    /// else branch) when the slot is absent or holds JSON `null` — both the common "not decided yet" case.
    /// A slot that is *present with a non-null, non-`Bool` value* is an authoring error (the body wrote the
    /// wrong type to the condition slot); it still reads `false` for safety, but is logged as a warning
    /// rather than silently swallowed.
    private func readConditionBool(_ id: UUID) async -> Bool {
        guard let data = await context.getSlot(id) else { return false }
        if let value = try? JSONDecoder().decode(Bool.self, from: data) { return value }
        // A present JSON `null` is a legitimate "undecided" — treat it like an absent slot, no warning.
        if (try? JSONDecoder().decode(Bool?.self, from: data)) == .some(nil) { return false }
        logger.log(.warning,
            "condition slot \(id.uuidString.prefix(8)) is not a Bool "
            + "(got \(preview(data))); reading as false")
        return false
    }

    /// Pretty-prints a finished parallel group as a tree.
    private func flushParallelPrettyLog(_ bundle: ParallelPrettyLogBundle) {
        if bundle.executedCount > 1 {
            for (i, line) in bundle.numberedLines.enumerated() {
                let marker = (i == 0) ? "┌ " : "│ "
                logger.log(.verbose, "\(marker)\(line)")
            }
            logger.log(.verbose, "└ parallel (\(bundle.executedCount) tasks)")
        } else {
            for line in bundle.numberedLines {
                logger.log(.verbose, line)
            }
        }
    }
}

// MARK: - Task Dispatch

private extension GraphWalker {

    /// Operation labels worth tracing when they appear as a *nested* task (inside a
    /// `$slot.set { … }` value subgraph). Plumbing ops (constant / stateGet / stateSet)
    /// are intentionally excluded to keep nested logging meaningful.
    static let tracedNestedLabels: Set<String> = [
        "model", "router", "dagPlan", "relevanceRank", "clientAction", "summarize", "memoryQuery", "memoryStore",
    ]

    func executeTaskCounting(
        _ task: PipelineExecutionGraph.Task,
        parallelBranchIndex: Int?,
        logCountedSteps: Bool
    ) async throws -> (ExecutionValue, Int) {
        if !logCountedSteps {
            let (result, nested) = try await runOperationCounting(
                task.operation,
                subgraphLog: false,
                surfaceTask: false,
                modelTaskID: task.id
            )
            return (result, nested)
        }

        let info = StepInfo(
            taskID: task.id,
            operationLabel: task.operation.label,
            prettyLabel: task.operation.prettyLabel,
            slotID: task.operation.slotID
        )
        let loc = String(task.id.uuidString.prefix(8)).lowercased()

        // Tasks inside a reactive loop body live outside the prefix-skip ordinal space: they take
        // no walk ordinal and are never skipped, so the body re-runs in full on each pass.
        if !(await context.isInLoopScope) {
            let ordinal = await context.takeWalkOrdinal()
            if await context.shouldSkipWalkTask(ordinal: ordinal) {
                // Offset-only prefix skip: slots already carry forward pass-1 values across
                // iterations, and the run's final value is preserved by `PipelineWalker.run`
                // when the pass produced no new surface work. Most skipped tasks return an empty
                // placeholder — its consumer (outer `.sequential` last-step / `.parallel`)
                // either overwrites it or discards it.
                //
                // **Exception:** `stateGet` must still yield the current slot bytes. Otherwise
                // `returnWith($someSlot.get())` after re-execution throws `EarlyReturn` with
                // empty `Data()`, breaking JSON decode of the pipeline `Output` in hosts like
                // the playground REPL.
                await context.emit(.stepSkipped(info))
                if case let .stateGet(slotID, _, _, defaultJSON) = task.operation {
                    let value = await context.getSlot(slotID) ?? Data(defaultJSON.utf8)
                    return (value, 0)
                }
                return (Data(), 0)
            }
        }

        await context.record(
            ExecutionContext.TraceEntry(
                taskID: task.id,
                operationLabel: task.operation.label,
                startedAt: Date()
            )
        )
        await context.emit(.stepStarted(info))
        if logCountedSteps {
            // Mirror of the completion line below — lets observers (e.g. the demo's live
            // DSL view) light up a node the moment it starts, not only when it finishes.
            logger.log(.verbose, "▶ \(task.operation.prettyLabel)  ← \(loc)")
        }

        // Timing is included on the `prettyLabel` log line below; avoid a second timing line here.
        let taskTimer = ElapsedTimer()
        do {
            let (result, nested) = try await runOperationCounting(
                task.operation,
                subgraphLog: false,
                surfaceTask: true,
                modelTaskID: task.id
            )
            let duration = taskTimer.nanoseconds()
            await context.recordSurfaceTaskExecuted()
            await context.finishTraceEntry(taskID: task.id, durationNanoseconds: duration, failed: false)
            if logCountedSteps {
                let body =
                    "\(task.operation.prettyLabel)  → \(preview(result))  ← \(loc)  (\(duration.prettyDuration))"
                let buffering = await context.walkerBuffersExecuteLines()
                if buffering, let branch = parallelBranchIndex {
                    // Only **surface** tasks of a `.parallel` branch get a numbered line —
                    // one per top-level walk task, not per nested subgraph op.
                    await context.walkerAppendBufferedExecuteLine(
                        branchIndex: branch,
                        lineBodyWithoutStepNumber: body
                    )
                } else if !buffering {
                    let line = await context.walkerFormatSequentialExecuteLine(body)
                    logger.log(.verbose, line)
                }
            }
            await context.emit(.stepCompleted(info, resultPreview: preview(result), duration: duration))
            return (result, 1 + nested)
        } catch {
            let duration = taskTimer.nanoseconds()
            await context.finishTraceEntry(taskID: task.id, durationNanoseconds: duration, failed: true)
            logger.log(.warning, "✗ \(task.operation.prettyLabel)  ← \(loc)  \(error)")
            await context.emit(.stepFailed(info, error: error, duration: duration))
            throw error
        }
    }

    func preview(_ value: ExecutionValue, maxLength: Int = 60) -> String {
        let raw = String(decoding: value, as: UTF8.self)
        return raw.count > maxLength ? String(raw.prefix(maxLength - 3)) + "..." : raw
    }

    /// Token-delta sink for a model step: maps each chunk to a `.modelOutputDelta` event on the
    /// run's observer. Returns nil when nothing observes the run or the step has no task id.
    private func makeModelDeltaSink(modelTaskID: UUID?) async -> (@Sendable (String) -> Void)? {
        guard let observer = await context.observer, let modelTaskID else { return nil }
        let path = delegatePathPrefix
        return { text in
            observer(.modelOutputDelta(taskID: modelTaskID, text: text, delegatePath: path))
        }
    }

    /// Resolves the slot-backed half of a model step's configuration into its arguments, immediately
    /// before the call.
    ///
    /// `ModelConfig` splits into what was known at lowering time (already in `arguments`) and what only
    /// a running pipeline can supply: injected context items, prior conversation turns, and the tool
    /// allowlist. All three are named by slot id and read here. Shared by `.model` and `.modelInput`
    /// so the two cannot drift — before this was factored out they resolved different subsets, and
    /// `.modelInput` silently ignored `priorTurnsSlotID`.
    ///
    /// The allowlist is an **intersection** with the catalog the step declared, never a replacement:
    /// a name the step does not advertise is ignored. Because narrowing is one-way, the slot is safe to
    /// fill from a model's own output — which is what lets a delegate parent hand each subagent the
    /// tool subset it asked for. Declaring the slot is itself the narrowing statement, so an unwritten
    /// slot grants **nothing** rather than everything: a skipped or missing write must not silently
    /// restore the full catalog.
    ///
    /// - Author: Claude
    private func resolveDeferredArguments(
        config: ModelConfig,
        into arguments: inout ModelArguments
    ) async throws {
        if !config.contextItemsSlotIDs.isEmpty {
            var allItems: [ContextItem] = []
            for slotID in config.contextItemsSlotIDs {
                guard let data = await context.getSlot(slotID) else { continue }
                do {
                    let items = try JSONDecoder().decode([ContextItem].self, from: data)
                    allItems.append(contentsOf: items)
                } catch {
                    throw ExecutionError.contextItemsDecodingFailed(slotID: slotID, underlyingError: error)
                }
            }
            if !allItems.isEmpty {
                arguments[.contextItems] = .contextItems(allItems)
            }
        }
        if let slotID = config.priorTurnsSlotID,
           let data = await context.getSlot(slotID) {
            do {
                let turns = try JSONDecoder().decode([ConversationTurn].self, from: data)
                arguments[.priorTurns] = .priorTurns(turns)
            } catch {
                throw ExecutionError.priorTurnsDecodingFailed(slotID: slotID, underlyingError: error)
            }
        }
        // Only narrow a step that actually declared tools, so an allowlist never *introduces* an empty
        // `tools` argument to a tool-free step (which would change the arguments a provider sees).
        if let slotID = config.toolAllowlistSlotID, !arguments.tools.isEmpty {
            var permitted: Set<String> = []
            if let data = await context.getSlot(slotID) {
                do {
                    permitted = Set(try JSONDecoder().decode([String].self, from: data))
                } catch {
                    throw ExecutionError.toolAllowlistDecodingFailed(slotID: slotID, underlyingError: error)
                }
            }
            arguments[.tools] = .tools(arguments.tools.filter { permitted.contains($0.name) })
        }
    }

    func runOperationCounting(
        _ operation: PipelineExecutionGraph.Operation,
        subgraphLog: Bool,
        surfaceTask: Bool,
        modelTaskID: UUID? = nil
    ) async throws -> (ExecutionValue, Int) {
        switch operation {

        case .constant(_, let jsonUTF8):
            return (Data(jsonUTF8.utf8), 0)

        case .stateGet(let slotID, _, _, let defaultJSON):
            let value = await context.getSlot(slotID) ?? Data(defaultJSON.utf8)
            return (value, 0)

        case let .stateSet(slotID, valueTypeName, valueGraph, debugLabel, writeKind):
            let (value, nested) = try await walkCountingNonSkippedTasks(
                valueGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            let out = try await StateSetOperation(context: context).execute(
                slotID: slotID,
                valueTypeName: valueTypeName,
                debugLabel: debugLabel,
                value: value,
                kind: writeKind
            )
            return (out, nested)

        case .model(let config, var arguments):
            try await resolveDeferredArguments(config: config, into: &arguments)
            let onDelta = await makeModelDeltaSink(modelTaskID: modelTaskID)
            do {
                let out = try await executor.runModel(config: config, arguments: arguments, onDelta: onDelta)
                return (out, 0)
            } catch ExecutorError.noBackend {
                return (.emptyJSON, 0)
            }

        case .modelInput(let config, var arguments, let inputGraph):
            let (input, nested) = try await walkCountingNonSkippedTasks(
                inputGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            arguments[.message] = .message(
                try JSONDecoder().decode(JSONValue.self, from: input)
            )
            try await resolveDeferredArguments(config: config, into: &arguments)
            let onDelta = await makeModelDeltaSink(modelTaskID: modelTaskID)
            do {
                let out = try await executor.runModel(config: config, arguments: arguments, onDelta: onDelta)
                return (out, nested)
            } catch ExecutorError.noBackend {
                return (.emptyJSON, nested)
            }

        case .classify(let textGraph, let task, let spec):
            let (textValue, nested) = try await walkCountingNonSkippedTasks(
                textGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            do {
                let out = try await executor.runClassification(text: textValue, task: task, spec: spec)
                return (out, nested)
            } catch ExecutorError.noBackend {
                return (try Self.unavailableClassification(for: task), nested)
            }

        case .dagPlan(let queryGraph, let tools, let hints):
            let (queryValue, nested) = try await walkCountingNonSkippedTasks(
                queryGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            do {
                let out = try await executor.runDAGPlan(query: queryValue, tools: tools, hints: hints)
                return (out, nested)
            } catch ExecutorError.noBackend {
                return (try JSONEncoder().encode(DAGPlanningResult(text: nil, dag: nil)), nested)
            }

        case .relevanceRank(let queryGraph, let tools, let topK):
            let (queryValue, nested) = try await walkCountingNonSkippedTasks(
                queryGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            do {
                let out = try await executor.runRelevanceRank(query: queryValue, tools: tools, topK: topK)
                return (out, nested)
            } catch ExecutorError.noBackend {
                // Passthrough: first topK tools at score 1.0 so the pipeline can still proceed.
                let fallback = RelevanceRankingResult(rankedTools: Array(tools.prefix(topK)).map { RankedTool(descriptor: $0, score: 1.0) })
                return (try JSONEncoder().encode(fallback), nested)
            }

        case .summarize(let slotID, _, let maxTokens):
            guard let text = await context.getSlot(slotID) else {
                return (.emptyJSON, 0)
            }
            let summarizeConfig = ModelConfig(outputTypeName: "String")
            let inputText = (try? JSONDecoder().decode(String.self, from: text))
                ?? String(decoding: text, as: UTF8.self)
            let summarizeArguments: ModelArguments = [
                ModelArgument.systemPrompt("").key: .systemPrompt("Summarize the following text to fit within \(maxTokens) tokens."),
                ModelArgument.message(.null).key: .message(.string(inputText))
            ]
            do {
                // Summarize is a model call routed through the executor seam with a summarize
                // system prompt and the slot text as the message (same arguments the executor
                // assembles for a `.model` step).
                let out = try await executor.runModel(
                    config: summarizeConfig,
                    arguments: summarizeArguments,
                    onDelta: nil
                )
                return (out, 0)
            } catch ExecutorError.noBackend {
                return (text, 0)
            }

        case .clientAction(let taskID, let inputGraph):
            let (inputValue, nested) = try await walkCountingNonSkippedTasks(
                inputGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            let out = try await ClientActionOperation(context: context).execute(
                taskID: taskID,
                inputValue: inputValue
            )
            // Record the result under the UUID slot and emit a stateUpdated event so observers
            // can track client-action outputs. Use draft kind — the task-ID slot is internal
            // bookkeeping and must NOT trigger graphProvider re-evaluation. A bare ClientTask
            // inside a While body would otherwise corrupt the cursor and prevent later
            // $state.set operations from ever executing.
            if surfaceTask {
                let prev = await context.getSlot(taskID)
                await context.setSlot(taskID, value: out)
                if prev != out {
                    await context.recordStateWrite(
                        slotID: taskID,
                        valueTypeName: "ClientAction",
                        debugLabel: nil,
                        previousValue: prev,
                        value: out,
                        kind: .draft
                    )
                }
            }
            return (out, nested)

        case .combine(let inputs):
            var items: [JSONValue] = []
            items.reserveCapacity(inputs.count)
            var nestedTotal = 0
            for input in inputs {
                let (value, nested) = try await walkCountingNonSkippedTasks(
                    input,
                    parallelBranchIndex: nil,
                    logCountedSteps: subgraphLog
                )
                nestedTotal += nested
                items.append(try JSONDecoder().decode(JSONValue.self, from: value))
            }
            return (try JSONEncoder().encode(JSONValue.array(items)), nestedTotal)

        case .contextProvide(let providerID, let queryGraph):
            let (queryValue, nested) = try await walkCountingNonSkippedTasks(
                queryGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            let out = try await ContextProvideOperation(context: context).execute(
                providerID: providerID,
                queryValue: queryValue
            )
            return (out, nested)

        case .memoryQuery(let quality, let queryGraph):
            let (queryValue, nested) = try await walkCountingNonSkippedTasks(
                queryGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            let out = try await MemoryQueryOperation(context: context).execute(
                quality: quality,
                queryValue: queryValue
            )
            return (out, nested)

        case .memoryStore(let planGraph, let mode):
            let (planValue, nested) = try await walkCountingNonSkippedTasks(
                planGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            let out = try await MemoryStoreOperation(context: context).execute(
                planValue: planValue,
                mode: mode
            )
            return (out, nested)

        case let .delegate(child, tasksSlotID, taskInputSlotID, budgetTotal, leafReserve, inherit):
            return try await runDelegate(
                child: child,
                tasksSlotID: tasksSlotID,
                taskInputSlotID: taskInputSlotID,
                budgetTotal: budgetTotal,
                leafReserve: leafReserve,
                inherit: inherit
            )

        }
    }

    /// Agent-side delegate fan-out. Reads `[JSONValue]` tasks from the parent scope, then runs one
    /// subagent per task — each in its **own** fresh `PipelineWalker` run (isolated `ExecutionContext`,
    /// task seeded into `taskInputSlotID`) but sharing this walker's `executor`, so every subagent
    /// resolves model steps against one shared model instance. Bounded by a ``SpawnBudget``; distilled
    /// results are gathered in task order into a JSON array.
    ///
    /// The subagent's graph is either the leaf's ``DelegateChild/embedded(_:)`` sub-graph, or — for
    /// ``DelegateChild/selfRecursion`` — the **enclosing root graph** re-run one level deeper via the
    /// ``selfDelegate`` capability (a delegate of the agent itself). Self-recursion shares **one** budget
    /// across the whole self-tree (created at the top, reused by every delegate via ``selfDelegateBudget``),
    /// so even an unbounded self-tree terminates.
    ///
    /// Warm-then-flood: the first subagent runs to completion (making the shared model resident)
    /// before the rest flood concurrently, so a cold thundering-herd can't each build their own
    /// instance. Refused tasks (beyond the budget) stay `null`.
    private func runDelegate(
        child: DelegateChild<PipelineExecutionGraph>,
        tasksSlotID: UUID,
        taskInputSlotID: UUID,
        budgetTotal: Int,
        leafReserve: Int,
        inherit: DelegateInheritance
    ) async throws -> (ExecutionValue, Int) {
        guard let tasksData = await context.getSlot(tasksSlotID),
              let tasks = try? JSONDecoder().decode([JSONValue].self, from: tasksData),
              !tasks.isEmpty else {
            return (try JSONEncoder().encode([JSONValue]()), 0)
        }

        let sharedExecutor = executor
        let ctx = context
        // Subagents run in isolated *state*. They inherit only the capabilities the parent explicitly
        // granted via `inherit` — tools, context providers, and/or memory — so a delegate is fully
        // isolated by default and the parent opts each child in to exactly what it needs.
        //
        // NOTE: granted `context`/`memory` providers are the parent's **same** instances, shared by every
        // concurrently-flooded subagent. State (slots) is isolated; provider *side effects* are not — two
        // subagents that both hold `.memory` may interleave stores with no ordering guarantee. Grant
        // `.memory`/`.context` only to providers whose writes are safe under concurrency.
        let capabilities = await context.inheritedCapabilities(inherit)

        // Forward a child run's `.delegateSubagent` transitions and `.modelOutputDelta` output up to this
        // run's observer, so both reach the root at any recursion depth. The child stamps the full
        // hierarchical path itself (via its own `delegatePathPrefix`), so events pass through unchanged.
        //
        // Everything else stays local. The filter exists to keep the root's *step* accounting to its own
        // steps — a subagent's `.taskStarted`/`.stepSkipped` describe a different graph and would corrupt
        // the root's progress model. Deltas are not step accounting: they are output, they carry the path
        // that says whose, and without forwarding them a host cannot show a subagent's turns at all.
        let parentObserver = await context.observer
        let forwardDelegateEvents: (@Sendable (ExecutionEvent) -> Void)? = parentObserver.map { observer in
            { event in
                switch event {
                case .delegateSubagent, .modelOutputDelta: observer(event)
                default: break
                }
            }
        }

        // Per-child source: an embedded sub-graph runs in a fresh nested walker; self-recursion re-runs
        // the enclosing root graph via the captured capability. Self-recursion reuses the self-tree's
        // shared budget (created once at the top) so the whole recursion is finite; embedded gets its
        // own budget.
        // `childPath` names the subagent within the whole delegate tree; the child run adopts it as its
        // own `delegatePathPrefix` so any delegate it in turn spawns keeps extending the same path.
        let prefix = delegatePathPrefix
        let budget: SpawnBudget
        let runSubagent: @Sendable (ExecutionValue, [Int]) async throws -> ExecutionValue
        switch child {
        case let .embedded(childGraph):
            budget = SpawnBudget(total: budgetTotal, leafReserve: leafReserve)
            runSubagent = { seed, childPath in
                try await PipelineWalker(executor: sharedExecutor).run(
                    graph: childGraph,
                    clientActionProvider: capabilities.clientActionProvider,
                    contextProviders: capabilities.contextProviders,
                    memoryProvider: capabilities.memoryProvider,
                    initialSlots: [taskInputSlotID: seed],
                    observingExecution: forwardDelegateEvents,
                    delegatePathPrefix: childPath
                )
            }
        case .selfRecursion:
            guard let selfDelegate else { throw ExecutionError.missingSelfDelegateCapability }
            let sharedBudget = selfDelegateBudget ?? SpawnBudget(total: budgetTotal, leafReserve: leafReserve)
            budget = sharedBudget
            runSubagent = { seed, childPath in
                try await selfDelegate(seed, taskInputSlotID, capabilities, sharedBudget, childPath, forwardDelegateEvents)
            }
        }

        @Sendable func runChild(_ task: JSONValue, index: Int) async throws -> JSONValue {
            let seed = try JSONEncoder().encode(task)
            let path = prefix + [index]
            // A child's tools are its parent's, so nothing else says which child is calling them.
            let out = try await SubagentIdentity.$current.withValue(
                SubagentIdentity(path: path, label: Self.subagentLabel(task))
            ) {
                try await runSubagent(seed, path)
            }
            let value = (try? JSONDecoder().decode(JSONValue.self, from: out)) ?? .null
            // Distilled return: reasoning models (e.g. LFM2.5) emit chain-of-thought before the answer.
            // Strip it from string results so the delegate gathers tiny answers, not transcripts.
            if case let .string(text) = value {
                return .string(Self.strippingReasoning(text))
            }
            return value
        }

        // Grant the whole delegate up front (warm-up unit + the flooded remainder) so we can report which
        // subagents run vs are refused before any work starts.
        let warmGranted = await budget.reserve(1)
        let restGranted = warmGranted == 1 ? await budget.reserve(tasks.count - 1) : 0
        let running = warmGranted + restGranted   // indices 0..<running actually run

        // Epochs are **waves**, not per-transition ticks, so a snapshot fold sees each wave as one
        // coherent set of siblings (the SwiftUI-preference analogy the client's `reduce` relies on):
        //   epoch 0 — initial membership (running / budget-refused),
        //   epoch 1 — the warm-up subagent's terminal,
        //   epoch 2 — the flooded remainder's terminals (one wave, landing concurrently).
        // Phase strings match `DelegatePhase` raw values; the client folds these back into a snapshot
        // (ExecutionEngine can't see the delegate observation types, so the wire stays primitive). Paths
        // are `delegatePathPrefix + [index]` so nested-delegate events carry a full hierarchical path.
        for index in tasks.indices {
            let phase = index < running ? "running" : "refused"
            await ctx.emit(.delegateSubagent(DelegateSubagentEvent(path: prefix + [index], phase: phase, cost: 0, epoch: 0)))
        }

        var results = [JSONValue](repeating: .null, count: tasks.count)
        guard running > 0 else { return (try JSONEncoder().encode(results), 0) }

        // All emissions below run on this task (the task group's result loop is sequential), so emitting
        // is race-free even though the epoch is fixed per wave rather than incremented per transition.
        func emitTerminal(_ index: Int, phase: String, cost: Int, epoch: Int) async {
            await ctx.emit(.delegateSubagent(DelegateSubagentEvent(path: prefix + [index], phase: phase, cost: cost, epoch: epoch)))
        }

        // A single subagent's failure is contained: it publishes `failed`, contributes a `null` result,
        // and never aborts the delegate — bounding the blast radius of any one erroring/weak subagent is
        // the whole point of a delegate. A caught child yields `nil` here (distinct from a subagent that
        // *succeeds* with a `null` answer, which yields `.some(.null)`).
        // Warm-up: one subagent to completion so the shared model is resident before concurrency.
        do {
            let value = try await runChild(tasks[0], index: 0)
            results[0] = value
            await emitTerminal(0, phase: "completed", cost: Self.approximateCost(value), epoch: 1)
        } catch {
            await emitTerminal(0, phase: "failed", cost: 0, epoch: 1)   // results[0] stays null
        }

        // Flood the rest concurrently; each failure is caught so one erroring subagent can't abort the
        // delegate. All terminals in this flood belong to one wave (epoch 2), reported as they land.
        if running > 1 {
            await withTaskGroup(of: (Int, JSONValue?).self) { group in
                for index in 1..<running {
                    let task = tasks[index]
                    group.addTask {
                        do { return (index, try await runChild(task, index: index)) }
                        catch { return (index, nil) }
                    }
                }
                for await (index, value) in group {
                    if let value {
                        results[index] = value
                        await emitTerminal(index, phase: "completed", cost: Self.approximateCost(value), epoch: 2)
                    } else {
                        await emitTerminal(index, phase: "failed", cost: 0, epoch: 2)   // results[index] stays null
                    }
                }
            }
        }

        return (try JSONEncoder().encode(results), running)
    }

    /// A rough per-subagent work signal for the live observation snapshot: the size of the distilled
    /// result (character count of a string answer, else its encoded byte count) as a stand-in for
    /// output tokens. This is deliberately approximate — exact token accounting would require the
    /// `Executor` seam to surface generation metrics, which the open walker cannot reach; that stays
    /// deferred. Zero until a subagent completes.
    static func approximateCost(_ value: JSONValue) -> Int {
        if case let .string(text) = value { return text.count }
        return (try? JSONEncoder().encode(value).count) ?? 0
    }

    /// A short name for a subagent, from the task it was seeded with. Bounded because it reaches both
    /// a person and every out-of-process call.
    static func subagentLabel(_ task: JSONValue) -> String? {
        let text: String
        if case let .string(value) = task {
            text = value
        } else if let data = try? JSONEncoder().encode(task) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            return nil
        }
        // A seed is written by a model and this reaches a consent dialog, so it is normalised here
        // rather than in a view: whitespace runs collapse to one space (which subsumes trimming), and
        // control characters go, since an escape sequence in a prompt is not something a person can
        // read past. It travels on the wire too, so a view-side fix would be too late.
        // A newline is both control and whitespace: dropped outright it would weld two words
        // together, so control characters that separate are kept for the collapse below to fold.
        let printable = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let collapsed = String(String.UnicodeScalarView(printable))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count <= 80 ? collapsed : String(collapsed.prefix(79)) + "…"
    }

    /// Strip a reasoning model's chain-of-thought from a raw answer: keep only what follows the last
    /// `</think>`, drop an unterminated `<think>` block, otherwise trim. Mirrors DelegateAgent's
    /// `DelegateDistiller.strippingReasoning` (kept in sync; the open engine can't depend on DelegateAgent).
    static func strippingReasoning(_ raw: String) -> String {
        if let close = raw.range(of: "</think>", options: [.caseInsensitive, .backwards]) {
            return String(raw[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let open = raw.range(of: "<think>", options: [.caseInsensitive]) {
            return String(raw[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Classification fallback

extension GraphWalker {
    /// The result a `.classify` step yields when no backend serves its task: the task's result shape
    /// marked `.unavailable`, so a pipeline can tell "nobody looked" from "nothing found".
    static func unavailableClassification(for task: ClassificationTask) throws -> ExecutionValue {
        switch task.kind {
        case .sequence, .zeroShotSequence:
            try JSONEncoder().encode(LabelScores.unavailable)
        case .token, .zeroShotToken:
            try JSONEncoder().encode(LabeledSpans.unavailable)
        }
    }
}
