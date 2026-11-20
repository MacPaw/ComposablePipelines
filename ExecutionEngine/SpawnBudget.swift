//
//  SpawnBudget.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// A global, shared accountant that bounds how many spawns a recursive fan-out may create — the
/// mechanism that turns "recursion is possible" into "the tree is provably finite".
///
/// Lives in `ExecutionEngine` so both the graph walker (executing a native delegate operation) and the
/// higher-level `DelegateAgent` dispatch helpers share one bounded-spawn primitive.
///
/// ## Termination invariant
///
/// A single `SpawnBudget` is shared by the whole tree. Its pools start summing to `total` and every
/// grant (`reserve`, `tryAcquireLeafSlot`) only *decrements* them; `release` returns only units that
/// were reserved but **not** spent on an actual spawn. Therefore the number of spawns that are
/// actually created across the entire run never exceeds `total`, so the tree is finite regardless of
/// how aggressively nodes try to fan out.
///
/// `release` exists for the reserve-then-conditionally-spawn pattern (reserve a subtree allotment, spawn
/// fewer, hand the slack back). The current in-graph delegate walker does not need it — every `reserve`
/// is immediately followed by the spawn with no suspension in between, so there is never an unspent
/// reservation to reclaim — but it remains part of the primitive's contract for callers that do defer.
///
/// ## Usage contract (reservation-on-descent)
///
/// Before a node fans out to `C` children it calls ``reserve(_:)`` for its whole subtree allotment and
/// spawns only the granted count — a wide top level therefore cannot drain the units that depth needs,
/// because each descending node claims its share up front. A node that ends up using fewer units than
/// it reserved calls ``release(_:)`` so siblings can use the slack (this never raises the spent total).
/// Leaves — the nodes that do the actual work — claim their slot with ``tryAcquireLeafSlot()``, which
/// draws on a dedicated reserve first so descent can never starve forward progress.
///
/// - Author: Claude
public actor SpawnBudget {

    /// The original hard cap. Retained so ``release(_:)`` can never inflate spendable capacity above it.
    private let total: Int
    /// Units available for descent reservations (non-leaf fan-out).
    private var descentPool: Int
    /// Units reserved exclusively for leaf forward-progress; descent reservations never touch these.
    private var leafReserve: Int

    /// - Parameters:
    ///   - total: Hard cap on the number of spawns the whole fan-out may create.
    ///   - leafReserve: Units held back so leaves can always make progress even once `descentPool`
    ///     is drained (anti-livelock). Must be `0...total`.
    public init(total: Int, leafReserve: Int = 1) {
        precondition(total >= 0, "SpawnBudget total must be non-negative")
        precondition(leafReserve >= 0 && leafReserve <= total,
                     "SpawnBudget leafReserve must be within 0...total")
        self.total = total
        self.leafReserve = leafReserve
        self.descentPool = total - leafReserve
    }

    /// Total units still available across both pools.
    public var available: Int { descentPool + leafReserve }

    /// Reserve up to `requested` units for descending into a subtree. Returns the number actually
    /// granted (`0...requested`) — the caller must spawn no more than that. Never draws on the leaf
    /// reserve. Granting `0` at exhaustion is how "refuse-at-zero" surfaces at the fan-out site.
    @discardableResult
    public func reserve(_ requested: Int) -> Int {
        guard requested > 0 else { return 0 }
        let granted = Swift.min(requested, descentPool)
        descentPool -= granted
        return granted
    }

    /// Return `n` reserved-but-unspent units to the descent pool (a subtree finished under its
    /// reservation, or a branch was cancelled). Defensively capped so that `descentPool + leafReserve`
    /// can never exceed the original `total`: even a caller that over-releases (a bug, or double-release)
    /// cannot inflate spendable capacity above the cap, preserving the termination invariant.
    public func release(_ n: Int) {
        guard n > 0 else { return }
        descentPool = Swift.min(descentPool + n, total - leafReserve)
    }

    /// A leaf claims one guaranteed slot to do work. Uses the dedicated leaf reserve first — so at
    /// least `leafReserve` leaves can always run even when descent has drained the pool — then falls
    /// back to the descent pool. Returns `false` only when the entire budget is exhausted.
    public func tryAcquireLeafSlot() -> Bool {
        if leafReserve > 0 {
            leafReserve -= 1
            return true
        }
        if descentPool > 0 {
            descentPool -= 1
            return true
        }
        return false
    }
}
