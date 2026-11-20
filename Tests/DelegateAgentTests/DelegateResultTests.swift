//
//  DelegateResultTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import DelegateAgent

/// Phase 2.2 — the distilled return stays tiny: chain-of-thought is stripped before it can reach the
/// parent, and the typed result round-trips.
final class DelegateResultTests: XCTestCase {

    func testStripsThinkBlockKeepingFinalAnswer() {
        let raw = "<think>let me reason at length about this…</think>The answer is 42."
        XCTAssertEqual(DelegateDistiller.strippingReasoning(raw), "The answer is 42.")
    }

    func testKeepsOnlyContentAfterLastThinkClose() {
        let raw = "<think>a</think>partial<think>b</think>final answer"
        XCTAssertEqual(DelegateDistiller.strippingReasoning(raw), "final answer")
    }

    func testDropsUnterminatedThinkBlock() {
        let raw = "prefix answer <think>reasoning that never closes"
        XCTAssertEqual(DelegateDistiller.strippingReasoning(raw), "prefix answer")
    }

    func testPlainOutputIsJustTrimmed() {
        XCTAssertEqual(DelegateDistiller.strippingReasoning("  just an answer\n"), "just an answer")
    }

    func testDistillStripsCoTAndCarriesMetadata() {
        let result = DelegateDistiller.distill(
            id: "root.0.2", raw: "<think>…</think>done", confidence: 0.8, cost: 120)
        XCTAssertEqual(result.answer, "done")
        XCTAssertEqual(result.id, "root.0.2")
        XCTAssertEqual(result.confidence, 0.8)
        XCTAssertEqual(result.cost, 120)
    }

    func testDelegateResultRoundTrips() throws {
        let original = DelegateResult(id: "a", answer: "hi", confidence: 0.5, cost: 7)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DelegateResult.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
