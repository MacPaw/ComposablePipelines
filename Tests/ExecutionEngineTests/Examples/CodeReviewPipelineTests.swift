//
//  CodeReviewPipelineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
@testable import Examples
@testable import ExecutionEngine

/// End-to-end execution of ``CodeReviewPipeline``: triage routes between an early `return` and an
/// escalation to a second model, and each model step carries its requested `requirements`.
final class CodeReviewPipelineTests: XCTestCase {

    /// Records every model call so tests can assert the requested `requirements`.
    private final class CallLog: @unchecked Sendable {
        private let lock = Lock()
        private(set) var calls: [ScriptedExecutor.ModelCall] = []
        func record(_ call: ScriptedExecutor.ModelCall) {
            lock.lock(); calls.append(call); lock.unlock()
        }
    }

    /// Triage replies "trivial" when the diff mentions a typo, else "needs-review". The deep
    /// review (when reached) returns a fixed marker so the test can detect that it ran.
    private func reviewExecutor(log: CallLog) -> ScriptedExecutor {
        ScriptedExecutor { call in
            log.record(call)
            if call.instructions.contains("Triage this diff") {
                return ScriptedExecutor.string(call.input.contains("typo") ? "trivial" : "needs-review")
            }
            return ScriptedExecutor.string("DEEP-REVIEW-RAN")
        }
    }

    // MARK: - Trivial diff: early return, no expensive call

    func testTrivialDiff_returnsEarly_andSkipsDeepReview() async throws {
        let pipeline = CodeReviewPipeline(diff: "fix a typo in a comment")
        let log = CallLog()
        let (result, events) = try await PipelineRun.runReactive(pipeline, executor: reviewExecutor(log: log))

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "LGTM — trivial change, no deep review needed.")
        XCTAssertTrue(
            events.slotHistory(pipeline.$review.id).isEmpty,
            "Trivial diffs must early-return before the deep-review model writes `review`."
        )
        XCTAssertEqual(log.calls.count, 1, "Only the triage model should run for a trivial diff.")
    }

    // MARK: - Non-trivial diff: escalation

    func testNonTrivialDiff_escalatesToDeepReview() async throws {
        let pipeline = CodeReviewPipeline(diff: "rewrite the authentication flow")
        let log = CallLog()
        let (result, events) = try await PipelineRun.runReactive(pipeline, executor: reviewExecutor(log: log))

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: try XCTUnwrap(events.lastValue(forSlot: pipeline.$verdict.id))), "needs-review")
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: try XCTUnwrap(events.lastValue(forSlot: pipeline.$review.id))), "DEEP-REVIEW-RAN")
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "DEEP-REVIEW-RAN")
        XCTAssertEqual(log.calls.count, 2, "Triage then deep review.")
    }

    // MARK: - requirements: are carried to the executor

    func testModelRequirements_arePassedThrough() async throws {
        let pipeline = CodeReviewPipeline(diff: "rewrite the authentication flow")
        let log = CallLog()
        _ = try await PipelineRun.runReactive(pipeline, executor: reviewExecutor(log: log))

        let triage = try XCTUnwrap(log.calls.first { $0.instructions.contains("Triage this diff") })
        let deep = try XCTUnwrap(log.calls.first { $0.instructions.contains("thorough code review") })

        XCTAssertEqual(triage.requirements?.traits, [.quick, .localOnly])
        XCTAssertEqual(deep.requirements?.traits, [.reasoning])
    }
}
