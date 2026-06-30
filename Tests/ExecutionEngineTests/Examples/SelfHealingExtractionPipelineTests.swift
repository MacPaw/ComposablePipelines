//
//  SelfHealingExtractionPipelineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
@testable import Examples
@testable import ExecutionEngine

/// End-to-end execution of ``SelfHealingExtractionPipeline``: the `While` loop must re-ask the
/// model each failed attempt, stop as soon as the output validates, and respect the attempt cap.
final class SelfHealingExtractionPipelineTests: XCTestCase {

    /// Records each model prompt and returns invalid JSON for the first `failures` calls, then valid.
    private final class Model: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var prompts: [String] = []
        let failures: Int
        init(failures: Int) { self.failures = failures }
        func respond(_ instructions: String) -> ExecutionValue {
            lock.lock(); defer { lock.unlock() }
            prompts.append(instructions)
            return ScriptedExecutor.string(prompts.count <= failures ? "not json at all" : #"{"name":"Ada","age":36}"#)
        }
    }

    private func executor(_ model: Model) -> ScriptedExecutor {
        ScriptedExecutor { model.respond($0.instructions) }
    }

    // MARK: - Retry then succeed

    func testRetriesUntilValid_thenStops() async throws {
        let model = Model(failures: 1)
        let pipeline = SelfHealingExtractionPipeline(text: "Ada is 36", maxAttempts: 5)
        let (result, events) = try await PipelineRun.runReactive(pipeline, executor: executor(model))

        XCTAssertEqual(model.prompts.count, 2, "One failed attempt, then one that validates — no more.")
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), #"{"name":"Ada","age":36}"#)

        XCTAssertEqual(
            events.slotHistoryStrings(pipeline.$candidate.id),
            ["not json at all", #"{"name":"Ada","age":36}"#],
            "candidate moves invalid → valid across the two attempts."
        )
        let attempts = events.slotHistory(pipeline.$attempts.id).map { (try? JSONDecoder().decode(Int.self, from: $0)) ?? -1 }
        XCTAssertEqual(attempts, [1, 2])
    }

    // MARK: - Error feedback reaches the retry prompt

    func testPreviousErrorIsFedIntoRetry() async throws {
        let model = Model(failures: 1)
        let pipeline = SelfHealingExtractionPipeline(text: "Ada is 36", maxAttempts: 5)
        _ = try await PipelineRun.runReactive(pipeline, executor: executor(model))

        XCTAssertEqual(model.prompts.count, 2)
        XCTAssertFalse(model.prompts[0].contains("previous attempt was rejected"), "First prompt has no prior error.")
        XCTAssertTrue(model.prompts[1].contains("previous attempt was rejected"), "Retry prompt carries the prior error.")
    }

    // MARK: - Attempt cap

    func testGivesUpAtMaxAttempts() async throws {
        let model = Model(failures: 99)
        let pipeline = SelfHealingExtractionPipeline(text: "Ada is 36", maxAttempts: 3)
        let (_, events) = try await PipelineRun.runReactive(pipeline, executor: executor(model))

        XCTAssertEqual(model.prompts.count, 3, "Stops after the attempt cap even though it never validates.")
        let lastValid = try XCTUnwrap(events.lastValue(forSlot: pipeline.$valid.id))
        XCTAssertEqual(try JSONDecoder().decode(Bool.self, from: lastValid), false)
    }
}
