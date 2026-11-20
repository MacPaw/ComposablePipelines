//
//  Binding+Map.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

extension Binding {
    /// Transforms the slot's value on the host — sugar over a single-input ``Run``:
    ///
    /// ```swift
    /// $draft.map { $0.split(whereSeparator: \.isWhitespace).count }
    ///     .assign(to: $wordCount)
    /// ```
    ///
    /// Lowers to the same `clientAction` leaf as ``Run``; pass `id:` for a stable
    /// cross-wire identity (see ``Run``).
    public func map<T: Sendable & Codable & Hashable>(
        id: String? = nil,
        _ transform: @escaping @Sendable (Value) async throws -> T
    ) -> Run<Value, T> {
        Run(id: id, self, action: transform)
    }

    /// Key-path spelling for pure one-liner projections:
    ///
    /// ```swift
    /// $draft.map(\.count)
    /// ```
    public func map<T: Sendable & Codable & Hashable>(
        _ keyPath: KeyPath<Value, T> & Sendable
    ) -> Run<Value, T> {
        Run(self) { $0[keyPath: keyPath] }
    }
}
