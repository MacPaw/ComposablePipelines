//
//  ClassifyOperationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineCompiler
import PipelineDSL
@testable import ExecutionEngine

/// The `.classify` leaf, walked end to end: DSL → lowering → compilation → the walker → the
/// `Executor` seam and back into the pipeline's typed result, plus the no-backend fallback.
final class ClassifyOperationTests: XCTestCase {

    private let lanes = ["answer directly", "needs a tool"]
    private let rules = ["Flag competitor mentions.", "Flag guaranteed returns."]

    /// Answers classification with a scripted result and records what it was handed.
    private struct ScriptedExecutor: Executor {
        struct Call: Equatable { let text: String; let task: ClassificationTask; let spec: ModelSpecDescriptor? }
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: Call?
            var value: Call? { lock.withLock { storage } }
            func set(_ value: Call) { lock.withLock { storage = value } }
        }

        /// `nil` reports `noBackend`, standing in for a runtime with no encoder for the task.
        let answer: (@Sendable (ClassificationTask) throws -> ExecutionValue)?
        let seen: Box

        func runModel(
            config: ModelConfig, arguments: ModelArguments, onDelta: (@Sendable (String) -> Void)?
        ) async throws -> ExecutionValue {
            throw ExecutorError.noBackend
        }

        func runClassification(
            text: ExecutionValue, task: ClassificationTask, spec: ModelSpecDescriptor?
        ) async throws -> ExecutionValue {
            let decoded = (try? JSONDecoder().decode(String.self, from: text))
                ?? String(decoding: text, as: UTF8.self)
            seen.set(Call(text: decoded, task: task, spec: spec))
            guard let answer else { throw ExecutorError.noBackend }
            return try answer(task)
        }
    }

    private func run<P: Pipeline>(
        _ pipeline: P,
        answer: (@Sendable (ClassificationTask) throws -> ExecutionValue)?
    ) async throws -> (P.Output, ScriptedExecutor.Call?) where P.Output: Decodable {
        let lowered = pipeline.lowered()
        let graph = PipelineCompiler().compile(lowered.graph)
        let box = ScriptedExecutor.Box()
        let out = try await PipelineWalker(executor: ScriptedExecutor(answer: answer, seen: box)).run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions)
        )
        return (try JSONDecoder().decode(P.Output.self, from: out), box.value)
    }

    private struct RoutingPipeline: Pipeline {
        typealias Output = PromptRouteDecision
        let prompt: String
        let lanes: [String]
        var body: some Pipeline { Classify(prompt, using: PromptRouter(lanes: lanes)) }
    }

    private struct DetectionPipeline: Pipeline {
        typealias Output = LabeledSpans
        let text: String
        var body: some Pipeline { Detect(text, using: PIIDetector()) }
    }

    private struct LintPipeline: Pipeline {
        typealias Output = LabeledSpans
        let text: String
        let rules: [String]
        var body: some Pipeline { Detect(using: PolicyLinter(rules: rules, threshold: 0.6)) { Just(value: text) } }
    }

    // MARK: - Sequence

    func testTheDecisionReachesThePipeline() async throws {
        let (decision, _) = try await run(RoutingPipeline(prompt: "weather?", lanes: lanes)) { _ in
            try JSONEncoder().encode(LabelScores(labels: self.lanes, scores: [0.2, 0.8]))
        }
        XCTAssertEqual(decision.scores, [0.2, 0.8])
        XCTAssertEqual(decision.topLabel, lanes[1])
        XCTAssertEqual(decision.topIndex, 1)
        XCTAssertTrue(decision.isEvaluated)
    }

    func testTheTextTaskAndSpecReachTheExecutor() async throws {
        let (_, call) = try await run(RoutingPipeline(prompt: "what's the weather in Kyiv?", lanes: lanes)) { _ in
            try JSONEncoder().encode(LabelScores(labels: self.lanes, scores: [0.5, 0.5]))
        }
        XCTAssertEqual(call?.text, "what's the weather in Kyiv?")
        XCTAssertEqual(call?.task, .zeroShotSequence(labels: lanes), "lane order is the pipeline's contract for reading it back")
        XCTAssertNil(call?.spec)
    }

    func testMissingBackendYieldsUndecidedRatherThanLaneZero() async throws {
        let (decision, _) = try await run(RoutingPipeline(prompt: "weather?", lanes: lanes), answer: nil)
        XCTAssertEqual(decision, .undecided)
        XCTAssertEqual(decision.status, .unavailable)
        XCTAssertNil(decision.topIndex, "an undecided route lets the pipeline take its own default")
    }

    // MARK: - Spans

    func testDetectedSpansReachThePipelineWithTheirOffsets() async throws {
        let text = "Email laura@charite.de today"
        let span = LabeledSpan(label: "contact.email", score: 0.99, utf16Range: 6..<22, text: "laura@charite.de")
        let (result, call) = try await run(DetectionPipeline(text: text)) { _ in
            try JSONEncoder().encode(LabeledSpans(spans: [span]))
        }
        XCTAssertEqual(call?.task, .token)
        XCTAssertEqual(result.spans, [span])
        let range = try XCTUnwrap(result.spans[0].range(in: text))
        XCTAssertEqual(String(text[range]), "laura@charite.de")
    }

    func testMissingBackendYieldsUnavailableNotACleanText() async throws {
        let (result, _) = try await run(DetectionPipeline(text: "Email laura@charite.de"), answer: nil)
        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(result.isEvaluated)
        XCTAssertNotEqual(result, LabeledSpans(spans: []), "not evaluated must never read as nothing found")
    }

    func testTheRulesAndThresholdReachTheExecutor() async throws {
        let (result, call) = try await run(LintPipeline(text: "AcmeAI is worse", rules: rules)) { task in
            guard case .zeroShotToken(let rules, _) = task else { throw ExecutorError.noBackend }
            return try JSONEncoder().encode(LabeledSpans(spans: [
                LabeledSpan(label: rules[0], score: 0.9, utf16Range: 0..<6, text: "AcmeAI"),
            ]))
        }
        XCTAssertEqual(call?.task, .zeroShotToken(labels: rules, threshold: 0.6))
        XCTAssertEqual(result.spans(labeled: rules[0]).map(\.text), ["AcmeAI"])
        XCTAssertTrue(result.spans(labeled: rules[1]).isEmpty)
    }

    // MARK: - Seam

    func testDefaultSeamImplementationReportsNoBackend() async {
        // A partial executor must not have to implement classification to be usable.
        struct Bare: Executor {
            func runModel(
                config: ModelConfig, arguments: ModelArguments, onDelta: (@Sendable (String) -> Void)?
            ) async throws -> ExecutionValue { Data() }
        }
        do {
            _ = try await Bare().runClassification(text: Data(), task: .token, spec: nil)
            XCTFail("the default implementation must report noBackend")
        } catch ExecutorError.noBackend {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
