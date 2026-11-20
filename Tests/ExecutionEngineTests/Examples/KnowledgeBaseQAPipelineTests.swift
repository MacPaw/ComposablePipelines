//
//  KnowledgeBaseQAPipelineTests.swift
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

/// End-to-end execution of ``KnowledgeBaseQAPipeline``: retrieve → generate, with the retrieved
/// context actually reaching the model.
final class KnowledgeBaseQAPipelineTests: XCTestCase {

    private let knowledgeBase = InMemoryKnowledgeBase(documents: [
        "MLX runs models on Apple silicon.",
        "Swift is a systems programming language.",
        "Pipelines compose steps into a graph.",
    ])

    /// Reports whether the retrieved context (the model `input`) mentions MLX — proving the
    /// retrieved items, not the bare question, were handed to the model.
    private func groundingExecutor() -> ScriptedExecutor {
        ScriptedExecutor { call in
            ScriptedExecutor.string(call.input.contains("MLX") ? "GROUNDED:yes" : "GROUNDED:no")
        }
    }

    // MARK: - Retrieval (mid-execution state)

    func testContextSlot_holdsOnlyTheMatchingDocument() async throws {
        let pipeline = KnowledgeBaseQAPipeline(knowledgeBase: knowledgeBase, question: "What is MLX?")
        let (_, events) = try await PipelineRun.runOnce(pipeline, executor: groundingExecutor())

        let raw = try XCTUnwrap(events.lastValue(forSlot: pipeline.$context.id))
        let items = try JSONDecoder().decode([ContextItem].self, from: raw)
        XCTAssertEqual(
            items,
            [ContextItem(kind: .custom("doc"), source: "in-memory-kb", value: .string("MLX runs models on Apple silicon."))],
            "Retrieval must populate `context` with exactly the document matching the query."
        )
    }

    func testRetrievedContextReachesTheModel() async throws {
        let pipeline = KnowledgeBaseQAPipeline(knowledgeBase: knowledgeBase, question: "What is MLX?")
        let (result, events) = try await PipelineRun.runOnce(pipeline, executor: groundingExecutor())

        let answer = try XCTUnwrap(events.lastValue(forSlot: pipeline.$answer.id))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: answer), "GROUNDED:yes")
        XCTAssertEqual(result, answer, "Pipeline output is the generated answer.")
    }

    // MARK: - Step-over-step ordering

    func testRetrieveThenGenerate() async throws {
        let pipeline = KnowledgeBaseQAPipeline(knowledgeBase: knowledgeBase, question: "What is MLX?")
        let (_, events) = try await PipelineRun.runOnce(pipeline, executor: groundingExecutor())

        let contextWritten = try XCTUnwrap(events.firstStateUpdateIndex(forSlot: pipeline.$context.id))
        let answerWritten = try XCTUnwrap(events.firstStateUpdateIndex(forSlot: pipeline.$answer.id))

        XCTAssertLessThan(contextWritten, answerWritten, "Retrieval must precede generation.")
    }

    // MARK: - Empty retrieval

    func testNoMatchingDocuments_yieldsEmptyContext() async throws {
        let pipeline = KnowledgeBaseQAPipeline(knowledgeBase: knowledgeBase, question: "quantum entanglement")
        let (_, events) = try await PipelineRun.runOnce(pipeline, executor: groundingExecutor())

        let raw = try XCTUnwrap(events.lastValue(forSlot: pipeline.$context.id))
        XCTAssertEqual(try JSONDecoder().decode([ContextItem].self, from: raw), [])
    }
}
