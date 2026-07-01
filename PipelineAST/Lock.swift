//
//  Lock.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

#if canImport(Darwin)
import os
#elseif canImport(Glibc)
import Glibc
#endif

/// A small, fast mutual-exclusion lock used across the package's modules.
///
/// Backed by `os_unfair_lock` (via `OSAllocatedUnfairLock`) on Apple platforms and by
/// `pthread_mutex` elsewhere (Linux) — a genuine, cheap lock on every supported platform. Not
/// re-entrant. Hold it only around short, synchronous critical sections; never across an `await`.
public final class Lock: @unchecked Sendable {
    #if canImport(Darwin)
    private let unfair = OSAllocatedUnfairLock()

    public init() {}

    public func lock() { unfair.lock() }
    public func unlock() { unfair.unlock() }
    #else
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    public init() {
        mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    public func lock() { pthread_mutex_lock(mutex) }
    public func unlock() { pthread_mutex_unlock(mutex) }
    #endif

    /// Run `body` while holding the lock.
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
