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
        case guardrail(rules: [GuardrailRule])

        case model(
            instructions: PipelineExecutionGraph,
            tools: PipelineExecutionGraph,
            input: PipelineExecutionGraph,
            outputTypeName: String,
            requirements: ModelSelectionRequirements?
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

        /// Runs a ``ContextItemsProvider`` registered under `providerID`. The `query`
        /// subgraph must produce a `String`; the operation emits `[ContextItem]`.
        case contextProvide(providerID: UUID, query: PipelineExecutionGraph)

        case constant(valueTypeName: String, jsonUTF8: String)
    }
}
