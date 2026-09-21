//
//  PipelineGraph.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
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
    /// Two-layer workflow router. The runner decides how to satisfy this via resources.
    case router(query: PipelineGraph, tools: [ToolDescriptor])
    /// Task-planning DAG model. The runner decides how to satisfy this via resources.
    case dagPlan(query: PipelineGraph, tools: [ToolDescriptor], hints: [String])
    /// Relevance ranker: scores `tools` by relevance to `query` and returns those above `threshold`.
    case relevanceRank(query: PipelineGraph, tools: [ToolDescriptor], threshold: Float, topK: Int)
    /// LLM-style step: static ``ModelConfig`` (output type, selection requirements, slot references) plus pre-built ``ModelArguments``.
    case model(config: ModelConfig, arguments: ModelArguments)
    /// Model step whose message is produced by a nested pipeline at execution time.
    case modelInput(config: ModelConfig, arguments: ModelArguments, input: PipelineGraph)
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
    /// Frozen form of a committed ``executionStateSet``.
    ///
    /// Semantically identical to ``executionStateGet`` at runtime — reads the already-committed
    /// slot value without re-running the inner pipeline. The distinct case exists so that
    /// ``SlotAccess`` can treat it as a *write* rather than a read, which preserves the
    /// RAW/WAW ordering edges that existed before the slot was committed. Without this, the
    /// dependency-graph builder loses the edge between the frozen set and any subsequent
    /// explicit ``GetValue`` (``$binding.get()``), causing the topological sort to
    /// parallelize them — and the explicit get ends up inside a parallel block instead of
    /// being the last sequential result of the pipeline.
    ///
    /// **Why this case lives in PipelineAST (not PipelineCompiler):** `PipelineDSL` emits
    /// this case during graph lowering, and `PipelineCompiler` consumes it. Both modules
    /// depend on `PipelineAST` as the shared IR, so the signal must cross the DSL→compiler
    /// boundary here. The alternative — inferring write-for-ordering semantics purely inside
    /// `DependencyGraphBuilder` — would require `DependencyGraphBuilder` to know which slots
    /// were frozen during re-lowering, information that only exists at DSL emit time.
    case executionStateFrozenSet(id: UUID, valueTypeName: String, debugLabel: String?, defaultJSON: String)
    /// Executes action on the client side to utilize result it execution
    case clientAction(taskID: UUID, input: PipelineGraph)
    /// Evaluates each subgraph in order and emits a JSON array of the results.
    /// Feeds multi-input steps (e.g. a multi-binding client task) a single combined value.
    case combine([PipelineGraph])
    /// Runs a ``ContextItemsProvider`` registered under `providerID`. The `query`
    /// subgraph must produce a `String`; the operation emits `[ContextItem]`.
    case contextProvide(providerID: UUID, query: PipelineGraph)
    /// Runs the registered ``MemoryProvider``. The `query` subgraph must produce
    /// a `String`; the operation emits `[ContextItem]`.
    case memoryQuery(quality: MemoryQueryQuality, query: PipelineGraph)
    /// Evaluates a ``MemoryWritePlan`` and persists each entry through the
    /// registered ``MemoryProvider``.
    /// `mode` is optional for wire-format backward compat: old payloads without the key decode as
    /// `nil`, which the compiler and walker treat as `.sync`.
    case memoryStore(plan: PipelineGraph, mode: MemoryStoreMode?)
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
