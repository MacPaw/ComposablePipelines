//
//  ProvisionedDelegateResearchPipelineTests.swift
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

/// The atomic-per-subagent-context guarantee: the parent provisions each subagent only the corpus
/// slice its subtask needs, and each isolated delegate sees **exactly** that — never a sibling's slice or
/// the whole corpus.
final class ProvisionedDelegateResearchPipelineTests: XCTestCase {

    private let corpus = [
        "Swift is a language",
        "MLX runs on Apple silicon",
        "Git is version control",
    ]

    /// A subagent's input is its provisioned `SubagentEnvironment`; echo the documents it was given so
    /// the gathered answers reveal exactly what each subagent could see. The combine turn is tagged by
    /// its prompt.
    private func scripted() -> ScriptedExecutor {
        ScriptedExecutor { call in
            if call.instructions.contains("Combine these findings") {
                return ScriptedExecutor.string("combined")
            }
            let env = (try? JSONDecoder().decode(SubagentEnvironment.self, from: Data(call.input.utf8)))
                ?? .empty
            return ScriptedExecutor.string(env.documents.joined(separator: " | "))
        }
    }

    func testEachSubagentSeesOnlyItsProvisionedSlice() async throws {
        let pipeline = ProvisionedDelegateResearchPipeline(
            question: "swift language; mlx silicon", corpus: corpus)
        let (result, events) = try await PipelineRun.runReactive(pipeline, executor: scripted())

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "combined")

        // The gathered answers echo each subagent's visible documents.
        let answers = try JSONDecoder().decode(
            [String?].self, from: try XCTUnwrap(events.lastValue(forSlot: pipeline.$answers.id)))
        XCTAssertEqual(answers.count, 2)

        let swiftAgent = try XCTUnwrap(answers[0])
        XCTAssertTrue(swiftAgent.contains("Swift"), "the swift subagent got the swift doc")
        XCTAssertFalse(swiftAgent.contains("MLX"), "…and could NOT see the mlx doc")
        XCTAssertFalse(swiftAgent.contains("Git"), "…nor the unrelated git doc")

        let mlxAgent = try XCTUnwrap(answers[1])
        XCTAssertTrue(mlxAgent.contains("MLX"), "the mlx subagent got the mlx doc")
        XCTAssertFalse(mlxAgent.contains("Swift"), "…and could NOT see the swift doc")
        XCTAssertFalse(mlxAgent.contains("Git"), "…nor the unrelated git doc")
    }

    func testProvisioningSelectsPerSubtask() {
        // The parent's provisioning is a pure, per-subtask selection.
        XCTAssertEqual(ProvisionedDelegateResearchPipeline.select("swift language", from: corpus),
                       ["Swift is a language"])
        XCTAssertEqual(ProvisionedDelegateResearchPipeline.select("mlx silicon", from: corpus),
                       ["MLX runs on Apple silicon"])
        XCTAssertEqual(ProvisionedDelegateResearchPipeline.select("unrelated topic", from: corpus), [])
    }
}
