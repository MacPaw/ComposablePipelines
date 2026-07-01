//
//  CodingAgentAdapter.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines

/// Adapts the ``CodingAgentPipeline`` to the ``ChatAgent`` protocol: each message is one agent run
/// in the working directory, with `ExecutionEvent`s translated into UI-facing ``AgentEvent``s.
///
/// It keeps a short conversation history so follow-ups ("try again", "and?") have context; the
/// working directory is the durable memory (tools re-read it each turn). Swapping in a different
/// `ChatAgent` replaces this whole type. It is an `actor` so its history is safely mutated across
/// awaited turns.
public actor CodingAgentAdapter: ChatAgent {
    public nonisolated let name: String
    private let executor: any Executor
    private let jail: PathJail
    private let maxTurns: Int
    private let historyLimit: Int
    private let contextTokens: Int
    private let maxOutputTokens: Int
    private let compaction: Bool
    private var history: [(user: String, assistant: String)] = []

    public init(
        name: String = "coding agent",
        executor: any Executor,
        jail: PathJail,
        maxTurns: Int = 15,
        historyLimit: Int = 4,
        contextTokens: Int = 8_192,
        maxOutputTokens: Int = 4_096,
        compaction: Bool = true
    ) {
        self.name = name
        self.executor = executor
        self.jail = jail
        self.maxTurns = maxTurns
        self.historyLimit = historyLimit
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.compaction = compaction
    }

    public func send(
        _ message: String,
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> String {
        onEvent(.thinking)
        let pipeline = CodingAgentPipeline(
            task: composeTask(message), tools: defaultCodingTools(jail: jail), maxTurns: maxTurns,
            contextTokens: contextTokens, maxOutputTokens: maxOutputTokens, compaction: compaction)

        let result = try await PipelineRunner.run(pipeline, executor: executor) { event in
            switch event {
            case .reexecutionStarted:
                // Each loop iteration is a fresh model turn.
                onEvent(.thinking)
            case .stateUpdated(let update) where update.valueTypeName == ModelTurn.outputTypeName:
                // The model's decision for this turn. When it requests tools, surface any preamble
                // it wrote as interim reasoning, then the tool calls. (A tool-free turn is the final
                // answer and is delivered as the return value, so it is not echoed here.)
                if let turn = try? JSONDecoder().decode(ModelTurn.self, from: update.value),
                   let calls = turn.toolCalls, !calls.isEmpty {
                    if let reply = turn.reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onEvent(.reasoning(reply))
                    }
                    for call in calls {
                        onEvent(.toolCall(name: call.name, arguments: call.arguments))
                    }
                }
            default:
                break
            }
        }

        let reply = (try? JSONDecoder().decode(String.self, from: result))
            ?? String(decoding: result, as: UTF8.self)
        remember(user: message, assistant: reply)
        return reply
    }

    // MARK: - Conversation memory

    /// Prepend a bounded, concise summary of recent turns so follow-up messages have context.
    private func composeTask(_ message: String) -> String {
        guard !history.isEmpty else { return message }
        var lines = ["Earlier in this conversation:"]
        for turn in history {
            lines.append("User: \(turn.user)")
            lines.append("You: \(truncate(turn.assistant, limit: 500))")
        }
        lines.append("")
        lines.append("New request: \(message)")
        return lines.joined(separator: "\n")
    }

    private func remember(user: String, assistant: String) {
        history.append((user, assistant))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    private func truncate(_ s: String, limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }
}
