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
/// per-operation fallback (model → empty, guardrail → pass, summarize → original text), so a host
/// can ship a partial executor without crashing the walk.
public enum ExecutorError: Error, Sendable {
    case noBackend
}

/// The seam between the open walker and the execution layer.
///
/// `PipelineWalker` orchestrates the graph — traversal, epochs, state, parallel batching — and
/// calls an `Executor` to do the real work of a model or guardrail step. Implementations own
/// *how* a step runs (model backends, resource lifecycle, selection, caching); the walker knows
/// none of that. Elix ships a proprietary executor; `MockExecutor` is the open stand-in, and a
/// host can provide its own (e.g. routing model steps to a remote API).
public protocol Executor: Sendable {

    /// Run a model step over already-resolved inputs.
    /// - Throws: ``ExecutorError/noBackend`` if no model can satisfy the request.
    func runModel(
        instructions: ExecutionValue,
        tools: ExecutionValue,
        input: ExecutionValue,
        outputTypeName: String,
        requirements: ModelSelectionRequirements?
    ) async throws -> ExecutionValue

    /// Evaluate guardrail rules. Returns a JSON-encoded `Bool` (`true` == passes).
    /// - Throws: ``ExecutorError/noBackend`` if no guardrail backend is available.
    func runGuardrail(rules: [GuardrailRule]) async throws -> ExecutionValue
}

/// Open executor for demos and tests: no real backend. Every operation reports ``ExecutorError/noBackend``
/// so the walker exercises its fallback paths — matching the previous empty `.mock` resource heap.
public struct MockExecutor: Executor {

    public init() {}

    public func runModel(
        instructions: ExecutionValue,
        tools: ExecutionValue,
        input: ExecutionValue,
        outputTypeName: String,
        requirements: ModelSelectionRequirements?
    ) async throws -> ExecutionValue {
        throw ExecutorError.noBackend
    }

    public func runGuardrail(rules: [GuardrailRule]) async throws -> ExecutionValue {
        throw ExecutorError.noBackend
    }
}
