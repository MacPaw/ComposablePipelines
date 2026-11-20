//
//  PipelineExecutionGraph.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Optimized execution plan compiled from a `PipelineGraph` AST.
///
/// Independent tasks (no shared slot dependencies) are grouped into `.parallel` blocks.
/// The executor treats this as a scheduling instruction set — no further analysis needed at runtime.
public indirect enum PipelineExecutionGraph: Codable, Equatable, Sendable {
    case empty
    /// Ordered steps; each completes before the next starts.
    case sequential([PipelineExecutionGraph])
    /// Independent tasks with no shared dependencies; all start concurrently, all must complete.
    case parallel([PipelineExecutionGraph])
    /// Early exit with a value.
    case returnWith(PipelineExecutionGraph)
    /// Atomic, tracked unit of work.
    case task(Task)
    /// One reactive-loop iteration body (compiled from ``PipelineGraph/loop(_:)``). The walker runs
    /// the inner graph under a *loop scope*: commits are batched and flushed once when the body
    /// finishes (so a mid-body commit doesn't tear the iteration apart via re-execution), and the
    /// body's tasks are never prefix-skipped, so each re-lowering pass re-runs the whole iteration.
    case loopScope(PipelineExecutionGraph)
    /// Slot-driven conditional evaluated **in-graph** (compiled from ``PipelineGraph/branch(...)``):
    /// read the `Bool` in `conditionSlotID`, walk `then` when true else `otherwise`. Works without a
    /// `graphProvider`.
    case branch(conditionSlotID: UUID, then: PipelineExecutionGraph, otherwise: PipelineExecutionGraph)
    /// Slot-driven while loop iterated **in-graph** (compiled from ``PipelineGraph/whileLoop(...)``):
    /// while the `Bool` in `conditionSlotID` is true, walk `body` (which updates the slot). Works
    /// without a `graphProvider`.
    case whileLoop(conditionSlotID: UUID, body: PipelineExecutionGraph)
}

// MARK: - Task

extension PipelineExecutionGraph {
    /// Cancellable unit of work with a stable identity for tracing.
    public struct Task: Codable, Equatable, Sendable {
        public let id: UUID
        public let operation: Operation

        public init(id: UUID = UUID(), operation: Operation) {
            self.id = id
            self.operation = operation
        }
    }
}

// MARK: - Operation

extension PipelineExecutionGraph {
    /// Mirrors `PipelineGraphLeaf` cases but references `PipelineExecutionGraph` subgraphs
    /// instead of nested AST trees.
    public enum Operation: Codable, Equatable, Sendable {
        case classify(text: PipelineExecutionGraph, task: ClassificationTask, spec: ModelSpecDescriptor?)
        case dagPlan(query: PipelineExecutionGraph, tools: [ToolDescriptor], hints: [String])
        case relevanceRank(query: PipelineExecutionGraph, tools: [ToolDescriptor], topK: Int)

        case model(config: ModelConfig, arguments: ModelArguments)
        case modelInput(
            config: ModelConfig,
            arguments: ModelArguments,
            input: PipelineExecutionGraph
        )

        case summarize(slotID: UUID, valueTypeName: String, maxTokens: Int)

        /// Read an execution-state slot.
        ///
        /// `defaultJSON` is the JSON-encoded ``State.initialValue`` baked into the graph at
        /// emission time. The engine returns these bytes verbatim when the slot is unset, so
        /// callers don't have to seed `initialSlots` for read-only `@State` properties.
        case stateGet(slotID: UUID, valueTypeName: String, debugLabel: String?, defaultJSON: String)
        case stateSet(
            slotID: UUID,
            valueTypeName: String,
            value: PipelineExecutionGraph,
            debugLabel: String?,
            writeKind: StateWriteKind
        )

        case clientAction(taskID: UUID, input: PipelineExecutionGraph)

        /// Evaluates each input subgraph in order and emits a JSON array of the results.
        case combine(inputs: [PipelineExecutionGraph])

        /// Runs a ``ContextItemsProvider`` registered under `providerID`. The `query`
        /// subgraph must produce a `String`; the operation emits `[ContextItem]`.
        case contextProvide(providerID: UUID, query: PipelineExecutionGraph)

        /// Runs the registered ``MemoryProvider``. The `query` subgraph must produce
        /// a `String`; the operation emits `[ContextItem]`.
        case memoryQuery(quality: MemoryQueryQuality, query: PipelineExecutionGraph)

        /// Evaluates a ``MemoryWritePlan`` and persists each entry through the
        /// registered ``MemoryProvider``.
        case memoryStore(plan: PipelineExecutionGraph, mode: MemoryStoreMode)

        /// Agent-side delegate fan-out: run `child` once per task read from `tasksSlotID`, each in an
        /// isolated scope with the task seeded into `taskInputSlotID`, bounded by a ``SpawnBudget``
        /// (`budgetTotal` / `leafReserve`). Gathers distilled child results into a JSON array. `child`
        /// is an embedded sub-graph or ``DelegateChild/selfRecursion`` (re-run the enclosing root graph).
        case delegate(
            child: DelegateChild<PipelineExecutionGraph>,
            tasksSlotID: UUID,
            taskInputSlotID: UUID,
            budgetTotal: Int,
            leafReserve: Int,
            inherit: DelegateInheritance
        )

        case constant(valueTypeName: String, jsonUTF8: String)
    }
}
