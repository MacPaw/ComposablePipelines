//
//  ResearchAssistantPipelineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
@testable import Examples
@testable import ExecutionEngine

/// End-to-end execution of ``ResearchAssistantPipeline``: turn 1 the model calls a tool, the tool
/// runs and its result is appended to the transcript, turn 2 the model answers and the loop exits.
final class ResearchAssistantPipelineTests: XCTestCase {

    private let corpus = [
        "MLX runs models on Apple silicon.",
        "Swift is a systems programming language.",
    ]

    /// Calls `docs_search` on the first turn (no observation yet), then answers once the transcript
    /// contains the tool result.
    private func agentExecutor(answer: String) -> ScriptedExecutor {
        ScriptedExecutor { call in
            if call.input.contains("[docs_search]") {
                return ScriptedExecutor.turn(reply: answer)
            }
            return ScriptedExecutor.turn(toolCalls: [
                ToolCall(id: "t1", name: "docs_search", arguments: #"{"query":"MLX"}"#),
            ])
        }
    }

    // MARK: - Tool dispatch + multi-turn

    func testCallsToolThenAnswers() async throws {
        let pipeline = ResearchAssistantPipeline(
            question: "What does MLX do?",
            tools: [DocsSearchTool(corpus: corpus)],
            maxTurns: 5
        )
        let answer = "MLX runs models on Apple silicon."
        let (result, events) = try await PipelineRun.runReactive(pipeline, executor: agentExecutor(answer: answer))

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), answer)

        let turns = events.slotHistory(pipeline.$turns.id).map { (try? JSONDecoder().decode(Int.self, from: $0)) ?? -1 }
        XCTAssertEqual(turns, [1, 2], "One tool turn, then one answer turn.")

        let transcript = try JSONDecoder().decode(String.self, from: try XCTUnwrap(events.lastValue(forSlot: pipeline.$transcript.id)))
        XCTAssertTrue(
            transcript.contains("[docs_search] MLX runs models on Apple silicon."),
            "The tool ran and its observation was fed back into the transcript: \(transcript)"
        )
    }

    // MARK: - Direct answer (no tool)

    func testAnswersWithoutToolWhenModelRepliesImmediately() async throws {
        let pipeline = ResearchAssistantPipeline(
            question: "Say hi",
            tools: [DocsSearchTool(corpus: corpus)],
            maxTurns: 5
        )
        let executor = ScriptedExecutor { _ in ScriptedExecutor.turn(reply: "hi") }
        let (result, events) = try await PipelineRun.runReactive(pipeline, executor: executor)

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "hi")
        let turns = events.slotHistory(pipeline.$turns.id).map { (try? JSONDecoder().decode(Int.self, from: $0)) ?? -1 }
        XCTAssertEqual(turns, [1], "A direct reply ends the loop after one turn.")
    }
}
