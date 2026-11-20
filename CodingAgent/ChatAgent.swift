//
//  ChatAgent.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// A UI-agnostic event emitted by a ``ChatAgent`` while it works on a message.
///
/// The terminal UI renders these; keeping them free of any rendering detail is what lets a
/// different agent implementation drive the same UI.
public enum AgentEvent: Sendable {
    /// The agent started (or resumed) reasoning — show a "thinking" indicator.
    case thinking
    /// Interim narration the model produced alongside a tool call (not the final answer).
    case reasoning(String)
    /// The agent invoked a tool. `arguments` is the raw JSON argument string.
    case toolCall(name: String, arguments: String)
}

/// A conversational agent the terminal UI talks to. One `send` is one user turn: the agent works
/// (emitting ``AgentEvent``s as it thinks and calls tools) and returns its final text reply.
///
/// The UI depends only on this protocol, so swapping in another agent — a different model, a remote
/// service, a planner — is just another conformance; nothing in the UI changes.
public protocol ChatAgent: Sendable {
    /// Display name shown in the UI banner (e.g. "coding agent").
    var name: String { get }

    /// Handle one user message, streaming progress through `onEvent`, and return the final reply.
    func send(
        _ message: String,
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> String
}
