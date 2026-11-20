//
//  ConversationTurn.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// A single turn in a prior conversation, injected into a model call to provide history.
///
/// A turn is more than role-plus-text because an agent's history is more than that: an
/// assistant turn that asked for tools, and the results that answered it, are the two halves of
/// one exchange. Flattening them into prose and handing the lot back as a single `user` message
/// — which is what every agent here did until the wire was audited — tells the model that its
/// own past actions were somebody else's words.
///
/// ``ToolCall`` is reused rather than mirrored: it already carries exactly the `id`, `name` and
/// raw `arguments` a replayed assistant turn needs, and a second near-identical type would only
/// create a conversion that can drift.
public struct ConversationTurn: Codable, Hashable, Sendable {
    public let role: String
    public let content: String
    /// Tools this assistant turn asked for. `nil` on every other role.
    ///
    /// - Author: Claude
    public let toolCalls: [ToolCall]?
    /// The call this turn answers. `nil` unless `role == "tool"`.
    ///
    /// This is what binds a result back to its request: a provider handed a `tool` message whose
    /// `tool_call_id` matches nothing in the preceding assistant turn rejects the whole request,
    /// so the id has to survive the round trip rather than be regenerated.
    ///
    /// - Author: Claude
    public let toolCallID: String?
    /// A thinking model's reasoning for this assistant turn. `nil` on every other role, and on an
    /// assistant turn whose host chose not to carry it.
    ///
    /// Carried, not applied: whether it is shown to the model again is the model's chat template's
    /// decision (LFM2.5 keeps the turns after the last user message and strips earlier ones), and an
    /// executor can be told to drop it with the `replay_reasoning` parameter. The alternative — the
    /// host pasting it into prose — put the model's thoughts in the user's mouth.
    ///
    /// - Author: Claude
    public let reasoning: String?

    public init(role: String, content: String,
                toolCalls: [ToolCall]? = nil, toolCallID: String? = nil, reasoning: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.reasoning = reasoning
    }

    /// The model's own turn, as the model's: its text (the preamble before a call, or the answer),
    /// the calls it asked for, and the reasoning that led to them — unless that thought was cut off
    /// (``ModelTurn/reasoningTruncated``: the OpenAI-compatible provider's reasoning budget ran out, or
    /// the local decoder found a `<think>` that never closed), in which case a fragment would only
    /// poison the next request.
    ///
    /// - Author: Claude
    public static func assistant(_ turn: ModelTurn) -> ConversationTurn {
        ConversationTurn(
            role: "assistant",
            content: turn.reply ?? "",
            toolCalls: turn.toolCalls,
            reasoning: turn.reasoningTruncated ? nil : turn.reasoning)
    }
}
