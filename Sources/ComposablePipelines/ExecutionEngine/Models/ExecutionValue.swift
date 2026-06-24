//
//  ExecutionValue.swift
//  elix-toolchain
//
//  Created by Oleksandr Frankiv on 23.04.2026.
//

import Foundation

/// The canonical value type flowing through the execution graph.
///
/// All operation inputs and outputs are UTF-8 JSON bytes. Callers encode
/// typed values before injecting them (initial slots, client-action returns)
/// and decode them after receiving results.
public typealias ExecutionValue = Data

extension Data {
    /// JSON-encoded empty string — returned for missing slots and as a placeholder
    /// for operations whose output is not yet implemented.
    /// Matches `WalkerState`'s sentinel in `ComposablePipelines`.
    static let emptyJSON = Data("\"\"".utf8)
}
