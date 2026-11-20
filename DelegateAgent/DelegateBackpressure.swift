//
//  DelegateBackpressure.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Resource/backpressure signals folded into a ``DelegateSnapshot`` so the reader can show *why* the
/// delegate is (or isn't) flooding — not just what it's doing.
///
/// `queueDepth` and `kvHeadroom` are optional: they come from the inference layer and are `nil` when
/// that layer doesn't surface them (e.g. under a scripted backend or a server that hides the queue).
public struct DelegateBackpressure: Codable, Sendable, Hashable {
    /// Spawn units still available in the delegate's ``SpawnBudget``.
    public var budgetRemaining: Int
    /// Pending requests in the inference queue, if known.
    public var queueDepth: Int?
    /// Fraction of KV-cache headroom left, `0...1`, if known.
    public var kvHeadroom: Double?

    public init(budgetRemaining: Int = 0, queueDepth: Int? = nil, kvHeadroom: Double? = nil) {
        self.budgetRemaining = budgetRemaining
        self.queueDepth = queueDepth
        self.kvHeadroom = kvHeadroom
    }

    /// No signals known yet.
    public static let none = DelegateBackpressure()
}
