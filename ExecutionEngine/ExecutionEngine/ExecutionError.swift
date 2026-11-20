//
//  ExecutionError.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Errors thrown by the execution engine during graph walking.
public enum ExecutionError: Error {

    /// A graph node produced a value whose type did not match what was expected.
    /// Typically indicates a compiler / pipeline bug, not a user error.
    case typeMismatch(expected: String, got: Any.Type)

    /// A `.clientAction` task referenced a `taskID` the `clientActionProvider` did not handle
    /// (or the provider was omitted while the graph contains client actions).
    case missingClientAction(taskID: UUID)

    /// A `.contextProvide` task referenced a `providerID` with no registered
    /// ``ContextItemsProvider``. The caller must include an entry in
    /// `contextProviders` for every `From(provider:)` in the graph.
    case missingContextProvider(providerID: UUID)

    /// A `.memoryQuery` task ran without a registered ``MemoryProvider``.
    case missingMemoryProvider

    /// A `.constant` node could not be decoded from its JSON payload.
    case constantDecodingFailed(valueTypeName: String, underlyingError: any Error)

    /// A `.model` node's context-items slot contained data that could not be decoded as `[ContextItem]`.
    case contextItemsDecodingFailed(slotID: UUID, underlyingError: any Error)

    /// A `.model` node's prior-turns slot contained data that could not be decoded as `[ConversationTurn]`.
    case priorTurnsDecodingFailed(slotID: UUID, underlyingError: any Error)

    /// A `.model` node's tool-allowlist slot contained data that could not be decoded as `[String]`.
    /// Thrown rather than ignored: silently skipping a malformed allowlist would widen the step back to
    /// its full tool catalog, turning an authoring mistake into an invisible capability grant.
    case toolAllowlistDecodingFailed(slotID: UUID, underlyingError: any Error)

    /// Re-execution received a graph whose surface-task count (`actualGraphTaskCount`) is
    /// smaller than the prefix skip count carried over from the previous pass
    /// (`expectedSkipCount`). The pipeline broke the "prefix is structurally stable across
    /// re-execution" invariant — the new graph dropped tasks that already ran.
    case prefixShorterThanRecordedSkipCount(expectedSkipCount: Int, actualGraphTaskCount: Int)

    /// A `.delegate` leaf used ``DelegateChild/selfRecursion`` but the walker was run without a
    /// self-delegate capability (the root-graph re-run closure). The runtime that walks a self-cloning
    /// agent must supply it; a bare `PipelineWalker.run` cannot resolve "re-run myself".
    case missingSelfDelegateCapability

    /// A slot-driven in-graph `whileLoop` ran more than the allowed number of iterations without its
    /// condition slot becoming `false` — almost certainly a body that never falsifies the condition.
    case inGraphLoopExceededMaxIterations(Int)
}
