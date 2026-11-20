//
//  DelegateResult.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// The **distilled** return of a single subagent — a tiny typed value, *not* the subagent's
/// transcript. Keeping returns small is what stops the parent's context from being N×-ed by the flood
/// (a delegate of K subagents that each returned their full transcript would defeat the whole bet).
///
/// A worker produces one of these with a final compression step (a `Summarize` or a last `Model`
/// turn), after stripping the reasoning model's chain-of-thought via ``DelegateDistiller``.
///
/// - Author: Claude
public struct DelegateResult: Codable, Sendable, Hashable {
    /// Stable identifier of the subagent that produced this result (e.g. its run-id path).
    public var id: String
    /// The distilled answer or verdict — CoT already stripped, compressed to the essentials.
    public var answer: String
    /// The subagent's self-reported confidence in `answer`, `0...1`.
    public var confidence: Double
    /// Rough cost of producing this result (e.g. tokens), for the duty-cycle accounting the delegate bet
    /// is measured on. `0` when unknown.
    public var cost: Int

    public init(id: String, answer: String, confidence: Double = 1.0, cost: Int = 0) {
        self.id = id
        self.answer = answer
        self.confidence = confidence
        self.cost = cost
    }
}

/// Compresses a reasoning model's raw output into a distilled answer.
///
/// LFM2.5 is a reasoning model: it emits chain-of-thought *before* the answer. That CoT must never
/// reach the parent — it is large, and it is not the answer. ``strippingReasoning(_:)`` removes it so
/// the ``DelegateResult/answer`` stays tiny.
public enum DelegateDistiller {

    /// Returns just the final answer from a reasoning model's raw output.
    ///
    /// Handles the common `<think>…</think>answer` convention (keeping only what follows the last
    /// close tag), drops a leading unterminated `<think>` block, and otherwise returns the trimmed
    /// input unchanged.
    public static func strippingReasoning(_ raw: String) -> String {
        if let close = raw.range(of: "</think>", options: [.caseInsensitive, .backwards]) {
            return String(raw[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let open = raw.range(of: "<think>", options: [.caseInsensitive]) {
            // An open tag with no close: everything from the tag on is unterminated reasoning.
            return String(raw[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a distilled ``DelegateResult`` from a subagent's raw output, stripping the CoT.
    public static func distill(
        id: String,
        raw: String,
        confidence: Double = 1.0,
        cost: Int = 0
    ) -> DelegateResult {
        DelegateResult(id: id, answer: strippingReasoning(raw), confidence: confidence, cost: cost)
    }
}
