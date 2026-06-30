//
//  OpenAIChatExecutor.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST
import ExecutionEngine

public enum OpenAIChatExecutorError: Error, Equatable {
    case missingAPIKey
    case invalidBaseURL(String)
    case nonHTTPResponse
    case httpStatus(Int, String)
    case emptyResponse
}

public struct OpenAIChatExecutor: Executor {
    public struct Config: Sendable {
        public var baseURL: URL
        public var apiKey: String
        public var model: String

        public init(baseURL: URL, apiKey: String, model: String) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
        }

        public static func fromEnvironment(
            _ env: [String: String] = ProcessInfo.processInfo.environment
        ) throws -> Config {
            guard let key = env["OPENAI_API_KEY"], !key.isEmpty else {
                throw OpenAIChatExecutorError.missingAPIKey
            }
            let base = env["OPENAI_BASE_URL"] ?? "https://api.openai.com/v1"
            guard let url = URL(string: base) else {
                throw OpenAIChatExecutorError.invalidBaseURL(base)
            }
            return Config(baseURL: url, apiKey: key, model: env["OPENAI_MODEL"] ?? "gpt-4o-mini")
        }
    }

    let config: Config
    let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        let system = arguments.systemPrompt
        let user: String
        if case .string(let s)? = arguments.message { user = s } else { user = "" }
        let reply = try await chat(system: system, user: user,
                                   temperature: arguments.temperature,
                                   maxTokens: arguments.maxTokens)
        if config.outputTypeName == ModelTurn.outputTypeName {
            return try JSONEncoder().encode(ModelTurn(reply: reply))
        }
        return try JSONEncoder().encode(reply)
    }

    // MARK: - Wire types

    // `content` is optional on decode: OpenAI-compatible servers may omit it (or send null)
    // when a turn carries no text — e.g. a reasoning model truncated mid-thought
    // (`finish_reason: "length"`) or a tool-call-only response. We always send it on requests.
    private struct ChatMessage: Codable { let role: String; let content: String? }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let maxTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(messages, forKey: .messages)
            if let t = temperature { try c.encode(t, forKey: .temperature) }
            if let m = maxTokens { try c.encode(m, forKey: .maxTokens) }
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable { let message: ChatMessage }
        let choices: [Choice]
    }

    // MARK: - HTTP

    private func chat(
        system: String,
        user: String,
        temperature: Double?,
        maxTokens: Int?
    ) async throws -> String {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        // LLM generation is slow — a local or reasoning model can run for minutes.
        // URLSession's 60s default would abort those mid-flight, so allow much longer.
        req.timeoutInterval = 600
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: config.model,
                messages: [
                    .init(role: "system", content: system),
                    .init(role: "user",   content: user)
                ],
                temperature: temperature,
                maxTokens: maxTokens
            )
        )
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIChatExecutorError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIChatExecutorError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw OpenAIChatExecutorError.emptyResponse
        }
        return content
    }
}
