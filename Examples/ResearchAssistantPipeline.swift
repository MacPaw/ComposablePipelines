//
//  ResearchAssistantPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineDSL

/// A tool-calling research agent: the model either calls a tool or answers. Each turn, tool calls
/// are dispatched and their results appended to the transcript; the loop ends when the model
/// returns a final reply.
///
/// Demonstrates:
/// - `Model<String, ModelTurn>` — a model step whose output is a structured ``ModelTurn`` (a final
///   `reply` and/or a set of `toolCalls`), with `tools:` advertising the available tool schemas.
/// - Dispatching `ModelTurn.toolCalls` through a `ClientTask` against a ``ToolRegistry`` and feeding
///   the observations back into the transcript.
/// - `While` driving the multi-turn agent loop, bounded by a visible `turns` counter.
struct ResearchAssistantPipeline: Pipeline {
    typealias Output = String

    let question: String
    let maxTurns: Int
    let tools: [any ModelTool]

    @State var transcript: String
    @State var lastTurn: ModelTurn = ModelTurn()
    @State var reply: String = ""
    @State var turns: Int = 0

    init(question: String, tools: [any ModelTool], maxTurns: Int = 5) {
        self.question = question
        self.tools = tools
        self.maxTurns = maxTurns
        _transcript = State(wrappedValue: "User: \(question)")
    }

    private var systemPrompt: String {
        "You are a research assistant. Call a tool when you need information; otherwise answer."
    }

    var body: some Pipeline {
        While(condition: { reply.isEmpty && turns < maxTurns }) {
            // Snapshot the committed transcript at lowering so the dispatch task can extend it.
            let priorTranscript = transcript
            let registry = ToolRegistry(tools)

            $lastTurn.set {
                Model<ModelTurn>()
                    .tools(tools.map(\.descriptor))
                    .systemPrompt(systemPrompt)
                    .input { $transcript.get() }
            }
            // Run any tool calls and append their results; a turn with no tool calls leaves the
            // transcript unchanged (the model is answering, not researching).
            $transcript.set {
                ClientTask(input: $lastTurn) { turn in
                    guard let calls = turn.toolCalls, !calls.isEmpty else { return priorTranscript }
                    var updated = priorTranscript
                    for call in calls {
                        let output = try await registry.executeJSON(
                            toolName: call.name,
                            inputJSON: Data(call.arguments.utf8)
                        )
                        let text = (try? JSONDecoder().decode(String.self, from: output))
                            ?? String(decoding: output, as: UTF8.self)
                        updated += "\n[\(call.name)] \(text)"
                    }
                    return updated
                }
            }
            $reply.set {
                ClientTask(input: $lastTurn) { turn in turn.reply ?? "" }
            }
            $turns.set {
                ClientTask(input: $turns) { $0 + 1 }
            }
        }
        $reply.get()
    }
}

/// A self-contained client-side tool: returns the first corpus entry containing the query term.
/// A real tool would hit a search index or API; the authoring surface is the same.
struct DocsSearchTool: ModelTool {
    struct Input: Codable, Sendable { let query: String }
    typealias Output = String

    static let name = "docs_search"
    static let description = "Search the documentation for a query and return the best matching line."
    static let inputSchema: JSONSchema = .object(properties: ["query": .string], required: ["query"])

    let corpus: [String]

    func call(_ input: Input) async throws -> String {
        corpus.first { $0.localizedCaseInsensitiveContains(input.query) } ?? "no matching documentation"
    }
}
