//
//  DelegateAggregation.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// How a delegate decides its final answer *after* the parallel attempts land — the quality layer the
/// legacy `Router` approximated, but chosen after breadth-first flooding rather than before.
public enum DelegateCompletionPolicy: Sendable, Hashable {
    /// Keep every result; a downstream judge synthesizes one answer from them (no single winner here).
    case all
    /// The first result (in task order) whose confidence is at least `minConfidence`.
    case firstGood(minConfidence: Double)
    /// The answer agreed on by at least `n` subagents (majority vote by answer text); the winner is
    /// the highest-confidence member of the agreeing group.
    case quorum(Int)
    /// The single highest-confidence result.
    case bestOf
}

/// The outcome of applying a ``DelegateCompletionPolicy`` to a delegate's gathered results.
public struct DelegateAggregation: Sendable, Hashable {
    /// The selected answer, or `nil` when no result satisfies the policy (e.g. quorum not reached), or
    /// for ``DelegateCompletionPolicy/all`` where synthesis is deferred to a judge.
    public var winner: DelegateResult?
    /// The results backing the outcome — the quorum members, the single pick, or (for `.all`)
    /// everything the delegate returned.
    public var supporting: [DelegateResult]

    public init(winner: DelegateResult?, supporting: [DelegateResult]) {
        self.winner = winner
        self.supporting = supporting
    }
}

/// Selects a delegate's answer from its distilled returns per a completion policy. Pure and synchronous —
/// the (expensive, model-based) synthesis only happens for the judge (`.all`), everything else is a
/// selection over already-distilled results.
public enum DelegateAggregator {

    /// Apply `policy` to the delegate's `results` (already stripped of refused/absent subagents).
    public static func aggregate(
        _ results: [DelegateResult],
        policy: DelegateCompletionPolicy
    ) -> DelegateAggregation {
        switch policy {
        case .all:
            return DelegateAggregation(winner: nil, supporting: results)

        case let .firstGood(minConfidence):
            let pick = results.first { $0.confidence >= minConfidence }
            return DelegateAggregation(winner: pick, supporting: pick.map { [$0] } ?? [])

        case let .quorum(n):
            // Group by answer text; the group with the most votes (then highest confidence) wins. The
            // final tie-break is the answer text so the winner is **deterministic** — a `[String: …]`
            // dictionary iterates in nondeterministic order, so without a total ordering two groups tied
            // on both count and confidence could pick different winners across runs.
            var groups: [String: [DelegateResult]] = [:]
            for result in results { groups[result.answer, default: []].append(result) }
            let winning = groups
                .filter { $0.value.count >= n }
                .max { lhs, rhs in
                    if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
                    let lc = lhs.value.map(\.confidence).max() ?? 0
                    let rc = rhs.value.map(\.confidence).max() ?? 0
                    if lc != rc { return lc < rc }
                    return lhs.key > rhs.key   // total order: lexicographically-smaller answer wins
                }
            guard let group = winning?.value else { return DelegateAggregation(winner: nil, supporting: []) }
            let best = group.max { $0.confidence < $1.confidence }
            return DelegateAggregation(winner: best, supporting: group)

        case .bestOf:
            let best = results.max { $0.confidence < $1.confidence }
            return DelegateAggregation(winner: best, supporting: best.map { [$0] } ?? [])
        }
    }
}
