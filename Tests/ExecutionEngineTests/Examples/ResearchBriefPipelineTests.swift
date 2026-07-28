//
//  ResearchBriefPipelineTests.swift
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

/// End-to-end execution of ``ResearchBriefPipeline`` — the Tier-1 sugar showcase. Confirms the
/// composed graph (Barrier + GateGuardrail, unlabeled ForEach, InstructionsBuilder Model,
/// autoclosure While over structured `generating:` output, `map`, and a bare-binding return)
/// lowers, compiles, and walks to completion end to end.
final class ResearchBriefPipelineTests: XCTestCase {

    /// Approves on the first review pass; canned text for every String-output stage.
    private func executor(approveFeedback: String = "") -> ScriptedExecutor {
        ScriptedExecutor { call in
            switch call.outputTypeName {
            case "Review":
                let review = Review(approved: true, feedback: approveFeedback)
                return try JSONEncoder().encode(review)
            default:
                // extract-facts, write-brief, and revise stages all produce String.
                return try JSONEncoder().encode("BRIEF: \(call.input.prefix(20))")
            }
        }
    }

    func testDraftsBriefAndReturnsIt() async throws {
        let pipeline = ResearchBriefPipeline(
            question: "How does MLX schedule work on Apple silicon?",
            tone: "concise, technical",
            chunks: ["MLX runs on Apple silicon.", "It uses unified memory."]
        )

        let (result, _) = try await PipelineRun.runReactive(pipeline, executor: executor())

        let output = try JSONDecoder().decode(String.self, from: result)
        XCTAssertTrue(output.hasPrefix("BRIEF:"), "expected the drafted brief as output, got: \(output)")
    }

    func testBlockedInput_shortCircuitsAtGate() async throws {
        let pipeline = ResearchBriefPipeline(
            question: "banned content",
            tone: "concise",
            chunks: ["irrelevant"]
        )
        // GateGuardrail lowers to a Bool-output classification; deny it.
        let blocking = ScriptedExecutor(guardrailPasses: false) { call in
            try JSONEncoder().encode("BRIEF: \(call.input.prefix(20))")
        }

        // The run completes without trapping; the gate simply doesn't clear the barrier.
        _ = try await PipelineRun.runReactive(pipeline, executor: blocking)
    }
}
