//
//  PromptRoutedBranchTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL
import ComposablePipelines
@testable import ExecutionEngine

/// An encoder gate choosing which branch runs: the decision reaching a value-dependent branch through
/// the re-lowering loop, and what happens when no routing backend exists.
final class PromptRoutedBranchTests: XCTestCase {

    private static let lanes = ["answer directly", "needs a tool"]

    /// Serves routing with a fixed verdict and answers chat turns by echoing which branch ran.
    private struct GateExecutor: Executor {
        /// `nil` makes routing report `noBackend`, standing in for an agent with no encoder registered.
        let laneIndex: Int?

        func runModel(
            config: ModelConfig, arguments: ModelArguments, onDelta: (@Sendable (String) -> Void)?
        ) async throws -> ExecutionValue {
            let prompt = arguments.systemPrompt
            return try JSONEncoder().encode(prompt.isEmpty ? "answered" : prompt)
        }

        func runClassification(
            text: ExecutionValue, task: ClassificationTask, spec: ModelSpecDescriptor?
        ) async throws -> ExecutionValue {
            guard let laneIndex, case .zeroShotSequence(let lanes) = task else { throw ExecutorError.noBackend }
            var scores = Array(repeating: Float(0.1), count: lanes.count)
            scores[laneIndex] = 0.9
            return try JSONEncoder().encode(PromptRouteDecision(labels: lanes, scores: scores))
        }
    }

    /// Mirrors the demo's control flow: gate → `Bool` slot → plan step → a *second* guard on whether the
    /// plan actually produced work.
    private struct GatedPipeline: Pipeline {
        typealias Output = String
        let prompt: String
        /// What the plan step yields when the gate asks for a split. Empty stands in for a reasoning model
        /// that burned its token budget and never emitted the tool call.
        let planYields: [String]

        @State var gate = PromptRouteDecision.undecided
        @State var delegates = false
        @State var briefs: [String] = []
        @State var answer: String = ""

        var body: some Pipeline {
            $gate.set { Classify(prompt, using: PromptRouter(lanes: PromptRoutedBranchTests.lanes)) }
            $delegates.set { $gate.map { $0.topIndex == 1 } }

            if delegates {
                $briefs.set(planYields)
            }

            if !briefs.isEmpty {
                $answer.set { Model<String>.chat(systemPrompt: "delegated").message(prompt) }
            } else {
                $answer.set { Model<String>.chat(systemPrompt: "direct").message(prompt) }
            }
            $answer.get()
        }
    }

    private func run(laneIndex: Int?, planYields: [String] = ["a"]) async throws -> String {
        let pipeline = GatedPipeline(prompt: "what's the weather in Kyiv?", planYields: planYields)
        let value = try await PipelineRunner.run(
            pipeline, executor: GateExecutor(laneIndex: laneIndex))
        return try JSONDecoder().decode(String.self, from: value)
    }

    func testGateChoosingTheToolLaneTakesTheDelegateBranch() async throws {
        let answer = try await run(laneIndex: 1)
        XCTAssertEqual(answer, "delegated")
    }

    func testGateChoosingKnowledgeTakesTheDirectBranch() async throws {
        let answer = try await run(laneIndex: 0)
        XCTAssertEqual(answer, "direct")
    }

    func testGateAskingForASplitThatNeverMaterialisesFallsBackToAnswering() async throws {
        // Guarding the fan-out on the gate alone would delegate over nothing when the plan turn yields
        // no subtasks; the second guard is what keeps it on the direct path.
        let answer = try await run(laneIndex: 1, planYields: [])
        XCTAssertEqual(answer, "direct", "an empty split means the model could not divide this")
    }

    func testNoRoutingBackendAnswersDirectlyRatherThanFanningOut() async throws {
        // A host that wires only a chat backend must degrade to answering, not to a fan-out nobody asked for.
        let answer = try await run(laneIndex: nil)
        XCTAssertEqual(answer, "direct")
    }
}
