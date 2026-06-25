//
//  GraphWalker.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST
import PipelineCompiler

/// Recursively traverses a `PipelineExecutionGraph` and executes each node.
///
/// A fresh `GraphWalker` is created per `PipelineWalker.run(...)` call; it holds
/// the per-request `ExecutionContext` and the `Executor` it dispatches model and
/// guardrail work to. The walker knows nothing about resources or model backends.
///
/// The walker is a value type: capturing it in task-group or `async let` closures
/// is safe because its state lives entirely in the actor-isolated `context`.
struct GraphWalker: Sendable {

    // MARK: - Properties

    private let executor: any Executor
    private let context: ExecutionContext
    private let logger: PipelineLog

    /// Same logger used for numbered step / parallel tree lines (`…elix-engine.walker` under the engine).
    var stepVerboseLogger: PipelineLog { logger }

    // MARK: - Init

    init(executor: any Executor, context: ExecutionContext, logger: PipelineLog = .none) {
        self.executor = executor
        self.context = context
        self.logger = logger.subLogger("walker")
    }

    // MARK: - Walk

    /// Recursively evaluate a graph node and return its result value.
    ///
    /// `EarlyReturn` propagates untouched through every recursive call and is
    /// caught only at the `PipelineWalker.run(...)` entry point.
    func walk(_ graph: PipelineExecutionGraph) async throws -> ExecutionValue {
        let (value, _) = try await walkCountingNonSkippedTasks(graph, logCountedSteps: true)
        return value
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
        }
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

    func executeTaskCounting(
        _ task: PipelineExecutionGraph.Task,
        parallelBranchIndex: Int?,
        logCountedSteps: Bool
    ) async throws -> (ExecutionValue, Int) {
        if !logCountedSteps {
            let (result, nested) = try await runOperationCounting(
                task.operation,
                subgraphLog: false,
                surfaceTask: false
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

        await context.record(
            ExecutionContext.TraceEntry(
                taskID: task.id,
                operationLabel: task.operation.label,
                startedAt: Date()
            )
        )
        await context.emit(.stepStarted(info))

        // Timing is included on the `prettyLabel` log line below; avoid a second timing line here.
        let taskTimer = ElapsedTimer()
        do {
            let (result, nested) = try await runOperationCounting(
                task.operation,
                subgraphLog: false,
                surfaceTask: true
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

    func runOperationCounting(
        _ operation: PipelineExecutionGraph.Operation,
        subgraphLog: Bool,
        surfaceTask: Bool
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

        case .model(let instructionsGraph, let toolsGraph, let inputGraph, let outputTypeName, let requirements):
            let (instructions, ni) = try await walkCountingNonSkippedTasks(
                instructionsGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            let (tools, nt) = try await walkCountingNonSkippedTasks(
                toolsGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            let (input, nj) = try await walkCountingNonSkippedTasks(
                inputGraph,
                parallelBranchIndex: nil,
                logCountedSteps: subgraphLog
            )
            do {
                let out = try await executor.runModel(
                    instructions: instructions,
                    tools: tools,
                    input: input,
                    outputTypeName: outputTypeName,
                    requirements: requirements
                )
                return (out, ni + nt + nj)
            } catch ExecutorError.noBackend {
                return (.emptyJSON, ni + nt + nj)
            }

        case .guardrail(let rules):
            do {
                return (try await executor.runGuardrail(rules: rules), 0)
            } catch ExecutorError.noBackend {
                return (try JSONEncoder().encode(true), 0)
            }

        case .summarize(let slotID, _, let maxTokens):
            guard let text = await context.getSlot(slotID) else {
                return (.emptyJSON, 0)
            }
            do {
                // Summarize is a model call: route it through the executor with a summarize
                // prompt as instructions and the slot text as input (same arguments the
                // executor assembles for a `.model` step).
                let instructions = try JSONEncoder().encode(
                    "Summarize the following text to fit within \(maxTokens) tokens."
                )
                let out = try await executor.runModel(
                    instructions: instructions,
                    tools: .emptyJSON,
                    input: text,
                    outputTypeName: String(describing: String.self),
                    requirements: ModelSelectionRequirements(purpose: .summarize)
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

        }
    }
}
