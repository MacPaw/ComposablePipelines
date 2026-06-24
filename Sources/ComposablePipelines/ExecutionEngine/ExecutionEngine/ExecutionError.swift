//
//  ExecutionError.swift
//  elix-toolchain
//
//  Created by Oleksandr Frankiv on 20.04.2026.
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

    /// A `.constant` node could not be decoded from its JSON payload.
    case constantDecodingFailed(valueTypeName: String, underlyingError: any Error)

    /// Re-execution received a graph whose surface-task count (`actualGraphTaskCount`) is
    /// smaller than the prefix skip count carried over from the previous pass
    /// (`expectedSkipCount`). The pipeline broke the "prefix is structurally stable across
    /// re-execution" invariant — the new graph dropped tasks that already ran.
    case prefixShorterThanRecordedSkipCount(expectedSkipCount: Int, actualGraphTaskCount: Int)
}
