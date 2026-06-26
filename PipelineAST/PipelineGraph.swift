//
//  PipelineGraph.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Control-flow shape for execution (Codable for persistence / transport). Produced by lowering a DSL graph; **executors depend only on this module**, not on ``PipelineDSL``.
///
/// Conforms to ``Codable`` for persistence and transport (e.g. ``JSONEncoder`` / ``JSONDecoder``),
/// or any custom ``Encoder``/``Decoder`` via the synthesized ``Encodable``/``Decodable`` methods.
public indirect enum PipelineGraph: Codable, Sendable {
    case empty
    case sequence([PipelineGraph])
    /// Value-producing early exit (pseudo-Swift: `return …`).
    case returnWith(PipelineGraph)
    case leaf(PipelineGraphLeaf)
    /// Explicit grouping hint.
    /// - `sequential`: when true the compiler treats the content as a single atomic block (no internal parallelization).
    /// - `gate`: when true everything after this group must wait for it to complete.
    case group(sequential: Bool, gate: Bool, PipelineGraph)
    /// Reactive-loop body (one `While` iteration). Unlike `group`, the engine treats the content as
    /// a re-executable scope: its commits are batched and flushed once at the end of the iteration
    /// (so the body is not torn apart by a mid-body re-execution), and its tasks are never
    /// prefix-skipped — each re-lowering pass runs the body afresh until the loop condition is false.
    case loop(PipelineGraph)
}

extension PipelineGraph: Equatable {
    public static func == (lhs: PipelineGraph, rhs: PipelineGraph) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty):
            return true
        case let (.sequence(a), .sequence(b)):
            return a == b
        case let (.returnWith(a), .returnWith(b)):
            return a == b
        case let (.leaf(a), .leaf(b)):
            return a == b
        case let (.group(seqA, gateA, a), .group(seqB, gateB, b)):
            return seqA == seqB && gateA == gateB && a == b
        case let (.loop(a), .loop(b)):
            return a == b
        default:
            return false
        }
    }
}

public enum PipelineGraphLeaf: Codable, Equatable, Sendable {
    case guardrail(rules: [GuardrailRule])
    /// LLM-style step: lowered **instructions**, **tools**, and **input** subgraphs plus `outputTypeName` (e.g. `String(describing: Output.self)` from the DSL).
    case model(
        instructions: PipelineGraph,
        tools: PipelineGraph,
        input: PipelineGraph,
        outputTypeName: String,
        requirements: ModelSelectionRequirements?
    )
    /// Text summarization step; binding id and value types from the runner contract.
    case summarize(textBindingId: UUID, textBindingValueType: String, maxTokens: Int)
    /// Constant value leaf; `valueTypeName` matches the logical output type name; `jsonUTF8` is JSON from ``JSONEncoder``.
    case just(valueTypeName: String, jsonUTF8: String)
    /// Run nested `value` graph and persist its result into an execution slot (keyed by ``UUID``).
    case executionStateSet(
        id: UUID,
        valueTypeName: String,
        value: PipelineGraph,
        debugLabel: String?,
        writeKind: StateWriteKind
    )
    /// Read current value from an execution slot (keyed by ``UUID``).
    ///
    /// `defaultJSON` is the JSON-encoded ``State.initialValue`` baked at emission time. The
    /// engine returns these bytes when the slot is unset so a graph is fully self-contained —
    /// callers don't have to seed `initialSlots` for read-only `@State` properties.
    case executionStateGet(id: UUID, valueTypeName: String, debugLabel: String?, defaultJSON: String)
    /// Executes action on the client side to utilize result it execution
    case clientAction(taskID: UUID, input: PipelineGraph)
    /// Runs a ``ContextItemsProvider`` registered under `providerID`. The `query`
    /// subgraph must produce a `String`; the operation emits `[ContextItem]`.
    case contextProvide(providerID: UUID, query: PipelineGraph)
    case opaque(typeName: String)
}

extension PipelineGraph {
    /// Decode serialized bytes (default ``JSONDecoder``).
    public static func decode(from data: Data, using decoder: JSONDecoder = JSONDecoder()) throws -> PipelineGraph {
        try decoder.decode(PipelineGraph.self, from: data)
    }

    /// Encode to `Data` (default ``JSONEncoder``).
    public func encoded(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try encoder.encode(self)
    }
}
