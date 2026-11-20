//
//  DelegateAggregationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import DelegateAgent

/// Phase 4.1 — completion policies select the delegate's answer from its distilled returns.
final class DelegateAggregationTests: XCTestCase {

    private func result(_ id: String, _ answer: String, _ confidence: Double) -> DelegateResult {
        DelegateResult(id: id, answer: answer, confidence: confidence)
    }

    func testFirstGoodPicksFirstAtThreshold() {
        let results = [result("0", "meh", 0.3), result("1", "good", 0.9), result("2", "great", 0.95)]
        let out = DelegateAggregator.aggregate(results, policy: .firstGood(minConfidence: 0.8))
        XCTAssertEqual(out.winner?.answer, "good", "first result at/above the confidence bar")
    }

    func testQuorumRecoversMajorityAnswer() {
        // Noisy workers: individual answers disagree, but the majority is correct.
        let results = [
            result("0", "wrong", 0.9),
            result("1", "42", 0.5),
            result("2", "42", 0.6),
            result("3", "other", 0.8),
            result("4", "42", 0.4),
        ]
        let out = DelegateAggregator.aggregate(results, policy: .quorum(3))
        XCTAssertEqual(out.winner?.answer, "42", "the answer with >= 3 votes wins despite noisy siblings")
        XCTAssertEqual(out.supporting.count, 3)
        // The winner is the most confident member of the agreeing group.
        XCTAssertEqual(out.winner?.confidence, 0.6)
    }

    func testQuorumUnmetYieldsNoWinner() {
        let results = [result("0", "a", 0.9), result("1", "b", 0.9), result("2", "c", 0.9)]
        let out = DelegateAggregator.aggregate(results, policy: .quorum(2))
        XCTAssertNil(out.winner, "no answer reaches the quorum")
    }

    func testBestOfPicksHighestConfidence() {
        let results = [result("0", "x", 0.4), result("1", "y", 0.92), result("2", "z", 0.7)]
        let out = DelegateAggregator.aggregate(results, policy: .bestOf)
        XCTAssertEqual(out.winner?.answer, "y")
    }

    func testAllKeepsEveryResultForSynthesis() {
        let results = [result("0", "a", 0.5), result("1", "b", 0.6)]
        let out = DelegateAggregator.aggregate(results, policy: .all)
        XCTAssertNil(out.winner, "synthesis is deferred to the judge")
        XCTAssertEqual(out.supporting.count, 2)
    }

    /// Two answer groups tied on both vote count and max confidence must resolve to the **same** winner
    /// every run — the dictionary that backs grouping has no defined iteration order, so a stable
    /// tie-break (the answer text) is what makes the outcome deterministic.
    func testQuorumTieIsDeterministic() {
        // "alpha" and "omega" each get 2 votes at identical max confidence 0.9 — a total tie but for the
        // answer text. The lexicographically-smaller answer ("alpha") must win, every time.
        let results = [
            result("0", "omega", 0.9),
            result("1", "alpha", 0.9),
            result("2", "omega", 0.8),
            result("3", "alpha", 0.8),
        ]
        let winners = (0..<50).map { _ in
            DelegateAggregator.aggregate(results, policy: .quorum(2)).winner?.answer
        }
        XCTAssertEqual(Set(winners).count, 1, "the tie-break must be stable across runs")
        XCTAssertEqual(winners.first, "alpha", "lexicographically-smaller answer wins a total tie")
    }

    func testAggregationBeatsFirstWorkerUnderNoise() {
        // The first worker is confidently wrong; the majority is right. A single-worker delegate (take
        // the first) would be wrong, quorum recovers the correct answer.
        let results = [
            result("0", "WRONG", 0.99),
            result("1", "RIGHT", 0.5),
            result("2", "RIGHT", 0.5),
            result("3", "RIGHT", 0.5),
        ]
        let single = results.first?.answer
        let quorum = DelegateAggregator.aggregate(results, policy: .quorum(3)).winner?.answer
        XCTAssertEqual(single, "WRONG")
        XCTAssertEqual(quorum, "RIGHT", "aggregation is more accurate than a single (noisy) worker")
    }
}
