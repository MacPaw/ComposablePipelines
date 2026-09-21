//
//  ModelTurn.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
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

    public init(reply: String? = nil, toolCalls: [ToolCall]? = nil) {
        self.reply = reply
        self.toolCalls = toolCalls
    }
}
