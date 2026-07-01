//
//  UnfairLock+Portable.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

#if !canImport(os)
import PipelineAST

/// Portable stand-in for the slice of `os.OSAllocatedUnfairLock` this module uses on platforms
/// without the `os` module (Linux). Same shape as the Apple type for the `initialState:` +
/// `withLock` API; backed by ``Lock`` (a `pthread_mutex` on Linux).
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = Lock()
    private var state: State

    init(initialState: State) { self.state = initialState }

    @discardableResult
    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif
