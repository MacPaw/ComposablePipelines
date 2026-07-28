//
//  Executor.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Thrown by an ``Executor`` when no backend can satisfy an operation. The walker maps this to a
/// per-operation fallback (model → empty, summarize → original text), so a host can ship a partial
/// executor without crashing the walk.
public enum ExecutorError: Error, Sendable {
    case noBackend
}

/// The seam between the open walker and the execution layer.
///
/// `PipelineWalker` orchestrates the graph — traversal, epochs, state, parallel batching — and
/// calls an `Executor` to do the real work of a model step. Implementations own *how* a step runs
/// (model backends, resource lifecycle, selection, caching, token streaming); the walker knows none
/// of that. A proprietary runtime can ship its own executor; `MockExecutor` is the open stand-in,
/// and a host can provide its own (e.g. routing model steps to a remote API).
///
/// Guardrails are not a distinct seam operation: they lower to an ordinary model classification
/// (`GuardrailClassification`) and run through `runModel` like any other model step.
public protocol Executor: Sendable {

    /// Run a model step over the resolved ``ModelConfig`` and ``ModelArguments`` the walker
    /// assembled (message, system prompt, tools, injected context items / prior turns, sampling
    /// parameters).
    /// - Parameter onDelta: optional sink for incremental output tokens; pass-through for streaming
    ///   backends, ignored by non-streaming ones.
    /// - Throws: ``ExecutorError/noBackend`` if no model can satisfy the request.
    func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue

    /// Route a query string through the routing model and return the encoded ``WorkflowRoute`` raw value.
    /// - Parameters:
    ///   - tools: ranked candidate tools available for this turn; an empty list means no tools were selected.
    /// - Throws: ``ExecutorError/noBackend`` when no router resource is available;
    ///   the walker falls back to ``WorkflowRoute/default``.
    func runRouter(query: ExecutionValue, tools: [ToolDescriptor]) async throws -> ExecutionValue

    /// Plan a DAG for the given query using the available tools.
    /// - Throws: ``ExecutorError/noBackend`` when no planner resource is available;
    ///   the walker falls back to an empty ``DAGPlanningResult``.
    func runDAGPlan(query: ExecutionValue, tools: [ToolDescriptor], hints: [String]) async throws -> ExecutionValue

    /// Rank `tools` by relevance to `query`, returning at most `topK` above `threshold`.
    /// - Throws: ``ExecutorError/noBackend`` when no ranker resource is available;
    ///   the walker falls back to the first `topK` tools at score 1.
    func runRelevanceRank(query: ExecutionValue, tools: [ToolDescriptor], threshold: Float, topK: Int) async throws -> ExecutionValue
}

extension Executor {
    public func runRouter(query: ExecutionValue, tools: [ToolDescriptor]) async throws -> ExecutionValue {
        throw ExecutorError.noBackend
    }

    public func runDAGPlan(query: ExecutionValue, tools: [ToolDescriptor], hints: [String]) async throws -> ExecutionValue {
        throw ExecutorError.noBackend
    }

    public func runRelevanceRank(query: ExecutionValue, tools: [ToolDescriptor], threshold: Float, topK: Int) async throws -> ExecutionValue {
        throw ExecutorError.noBackend
    }
}

/// Open executor for demos and tests: no real backend. Every operation reports ``ExecutorError/noBackend``
/// so the walker exercises its fallback paths — matching the previous empty `.mock` resource heap.
public struct MockExecutor: Executor {

    public init() {}

    public func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        throw ExecutorError.noBackend
    }
}
