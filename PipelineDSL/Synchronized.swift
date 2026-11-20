//
//  Synchronized.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

// Internal on purpose: kept out of the public surface so it never collides with a consumer's own
// `Synchronized` (e.g. AtomicKit's) when they `import PipelineDSL`.
@propertyWrapper
final class Synchronized<Value>: @unchecked Sendable {

    private let lock = Lock()
    private var value: Value

    init(wrappedValue: Value) {
        self.value = wrappedValue
    }

    var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// The wrapper itself, for `$`-prefixed access (subscript / `write` / `read`).
    var projectedValue: Synchronized<Value> { self }

    /// Replace the value under the lock.
    func store(_ newValue: Value) {
        lock.withLock { value = newValue }
    }

    /// Mutate the value in place under the lock.
    @discardableResult
    func write<R>(_ body: (inout Value) -> R) -> R {
        lock.withLock { body(&value) }
    }

    /// Read the value under the lock.
    func read<R>(_ body: (Value) -> R) -> R {
        lock.withLock { body(value) }
    }
}

extension Synchronized {
    /// Dictionary access under the lock (used as `$slot[key]`).
    subscript<K: Hashable, V>(key: K) -> V? where Value == [K: V] {
        get { lock.withLock { value[key] } }
        set { lock.withLock { value[key] = newValue } }
    }
}
