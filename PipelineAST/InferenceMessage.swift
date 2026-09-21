//
//  InferenceMessage.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// A single message in a multi-turn model conversation.
///
/// Used by `Agent` (not yet implemented) to carry conversation history through
/// the tool-call dispatch loop. Providers receive `[InferenceMessage]` when a
/// `ModelArgument.messages` entry is present.
public enum InferenceMessage: Codable, Sendable {
    case system(content: String)
    case user(content: String)
    case assistant(content: String?, toolCalls: [ToolCall]?)
    case tool(callID: String, name: String, content: String)

    private enum CodingKeys: String, CodingKey {
        case role, content, toolCalls, callID, name
    }

    private enum Role: String, Codable {
        case system, user, assistant, tool
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Role.self, forKey: .role) {
        case .system:
            self = .system(content: try c.decode(String.self, forKey: .content))
        case .user:
            self = .user(content: try c.decode(String.self, forKey: .content))
        case .assistant:
            self = .assistant(
                content: try c.decodeIfPresent(String.self, forKey: .content),
                toolCalls: try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
            )
        case .tool:
            self = .tool(
                callID: try c.decode(String.self, forKey: .callID),
                name: try c.decode(String.self, forKey: .name),
                content: try c.decode(String.self, forKey: .content)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system(let content):
            try c.encode(Role.system, forKey: .role)
            try c.encode(content, forKey: .content)
        case .user(let content):
            try c.encode(Role.user, forKey: .role)
            try c.encode(content, forKey: .content)
        case .assistant(let content, let toolCalls):
            try c.encode(Role.assistant, forKey: .role)
            try c.encodeIfPresent(content, forKey: .content)
            try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        case .tool(let callID, let name, let content):
            try c.encode(Role.tool, forKey: .role)
            try c.encode(callID, forKey: .callID)
            try c.encode(name, forKey: .name)
            try c.encode(content, forKey: .content)
        }
    }
}
