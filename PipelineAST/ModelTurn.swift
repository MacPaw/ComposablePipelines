//
//  ModelTurn.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// One turn of a model's response — either a final reply or a set of tool calls.
///
/// Used as the provider's return type and as a first-class pipeline output type
/// (`Model<Input, ModelTurn>`) for pipelines that need to inspect tool calls.
public struct ModelTurn: Codable, Hashable, Sendable {
    public static let outputTypeName = "ModelTurn"

    public let reply: String?
    public let toolCalls: [ToolCall]?
    /// The exact text/payload sent to the model for this turn (the rendered prompt for
    /// local models, the request body for API backends). Optional — populated by the
    /// inference backend for observability; nil when not captured.
    public let promptText: String?
    /// A thinking model's internal reasoning for this turn, captured for observability ONLY.
    /// It never drives the agent loop and is not part of `reply` — surfacing it there would feed
    /// it back to the model and let a degenerate loop flood the transcript. Display use only.
    public let reasoning: String?
    /// The EXACT, un-decoded model completion for this turn — before any tool-call parsing or
    /// token stripping. `reply` is the cleaned answer and `toolCalls` the parsed calls; this is
    /// what the model literally emitted (e.g. `<|tool_call_start|>[…]<|tool_call_end|>`). Optional,
    /// display-only ("raw transcript mode"); never fed back to the model.
    public let rawOutput: String?
    /// Per-request token/time accounting the serving backend reported (usage + timings
    /// of an OpenAI-compatible response). Nil when the backend sent none.
    public let usage: [String: Double]?
    /// True when the serving backend force-closed this turn's think block because the
    /// reasoning budget ran out (detected via the injected sentinel) — the thought was
    /// cut, not finished. Distinguishes "the model stopped" from "the model was stopped".
    public let reasoningTruncated: Bool

    public init(reply: String? = nil, toolCalls: [ToolCall]? = nil, promptText: String? = nil,
                reasoning: String? = nil, rawOutput: String? = nil,
                usage: [String: Double]? = nil, reasoningTruncated: Bool = false) {
        self.reply = reply
        self.toolCalls = toolCalls
        self.promptText = promptText
        self.reasoning = reasoning
        self.rawOutput = rawOutput
        self.usage = usage
        self.reasoningTruncated = reasoningTruncated
    }
}
