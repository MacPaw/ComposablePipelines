//
//  DelegateReader.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// A **read-only** view over a reduced ``DelegateSnapshot``, mirroring SwiftUI's
/// `GeometryReader`/`ScrollViewReader` proxy: a body reads the live delegate shape through it but cannot
/// write it back. Reading the proxy must never mutate control state — v1 deliberately forbids
/// adaptive dispatch (feeding live delegate state back into spawning) to avoid the body-re-run feedback
/// loop the framework guards against.
public struct DelegateProxy: Sendable {
    private let snapshot: DelegateSnapshot

    init(snapshot: DelegateSnapshot) {
        self.snapshot = snapshot
    }

    /// The epoch this snapshot was reduced at.
    public var epoch: Int { snapshot.epoch }

    /// Every subagent status, ordered by tree position.
    public var tree: [DelegateStatus] { snapshot.statuses }

    /// Subagents currently doing work.
    public var activeCount: Int { snapshot.activeCount }

    /// Resource/backpressure signals at this epoch — why the delegate is (or isn't) flooding.
    public var backpressure: DelegateBackpressure { snapshot.backpressure }

    /// Spawn units still available in the delegate's budget.
    public var budgetRemaining: Int { snapshot.backpressure.budgetRemaining }

    /// The status of a specific subagent, if present.
    public func status(for id: DelegateRunID) -> DelegateStatus? { snapshot.status(for: id) }

    /// The direct children of `id` (subagents whose parent is `id`), ordered by tree position.
    public func children(of id: DelegateRunID) -> [DelegateStatus] {
        snapshot.statuses.filter { $0.runID.parent == id }
    }
}

/// Exposes the reduced live delegate state to a body as a read-only ``DelegateProxy`` — the delegate's analog
/// of `GeometryReader { proxy in … }`.
///
/// - Author: Claude
public enum DelegateReader {
    /// Read the `snapshot` through a read-only proxy and return whatever the body derives from it.
    public static func read<Result>(
        _ snapshot: DelegateSnapshot,
        _ body: (DelegateProxy) -> Result
    ) -> Result {
        body(DelegateProxy(snapshot: snapshot))
    }
}
