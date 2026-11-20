//
//  FinishTool.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST
import PipelineDSL

/// End the run with a final answer.
///
/// The loop otherwise ends only on a turn with no tool call, a move small models rarely make once
/// they are calling tools: they say "the task is complete" and still attach a call — often to a
/// `finish` that did not exist, retried until the turn budget ran out. A ``AgentLoop`` with
/// `.finishTool()` treats a call to this tool as the end of the run, and `message` as the answer. The tool itself only acknowledges; ending the run is the loop's decision, the same
/// way a tool-free reply is.
///
/// - Author: Claude
public struct FinishTool: ModelTool {
    public struct Input: Codable, Sendable {
        public let message: String?

        public init(message: String?) { self.message = message }

        // `message` is the key models already reach for when they invent this tool; the others
        // are its common spellings. An answer under any of them is still the answer.
        private enum CodingKeys: String, CodingKey { case message, summary, answer, result }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = try [CodingKeys.message, .summary, .answer, .result].lazy
                .compactMap { try c.decodeIfPresent(String.self, forKey: $0) }
                .first
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(message, forKey: .message)
        }
    }
    public typealias Output = String
    public static let name = "finish"
    public static let description = "End the task. Call this once the task is complete and verified. Input: {message} — your final answer or a short summary of what you did."
    public static let inputSchema: JSONSchema = .object(properties: ["message": .string], required: ["message"])

    public init() {}

    public func call(_ input: Input) async throws -> String {
        "finished"
    }

    /// The answer a `finish` call carries: its `message` when there is one, otherwise the text the
    /// model wrote beside the call, otherwise a note that it ended without one.
    public static func answer(arguments: String, fallback: String?) -> String {
        let message = (try? JSONDecoder().decode(Input.self, from: Data(arguments.utf8)))?.message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty { return message }
        if let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            return fallback
        }
        return "(finished without a summary)"
    }
}
