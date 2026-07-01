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

/// Resolved limits for a model: the total context window and the per-response output cap (in tokens).
public struct ModelCapabilities: Sendable, Equatable {
    public var contextTokens: Int
    public var maxOutputTokens: Int

    public init(contextTokens: Int, maxOutputTokens: Int) {
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
    }

    /// Conservative fallback when neither the API nor the environment reports limits.
    public static let `default` = ModelCapabilities(contextTokens: 8_192, maxOutputTokens: 4_096)

    /// Best-effort context window for well-known model families, used when neither the API nor the
    /// environment reports one. Deliberately small and conservative — many servers omit the real
    /// value, and this saves setting `OPENAI_CONTEXT_TOKENS` for common models. Override anytime.
    public static func knownContextWindow(forModelID id: String) -> Int? {
        let name = id.lowercased()
        if name.contains("gemma-4") || name.contains("gemma4") { return 262_144 }
        if name.contains("gemma-3") || name.contains("gemma3") { return 131_072 }
        if name.contains("qwen3") || name.contains("qwen-3") { return 262_144 }
        if name.contains("llama-3") || name.contains("llama3") { return 131_072 }
        return nil
    }
}

/// Token usage reported by the server for one response. `promptTokens` is the context consumed.
public struct Usage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct OpenAIChatExecutor: Executor {
    public struct Config: Sendable {
        public var baseURL: URL
        public var apiKey: String
        public var model: String
        /// Optional capability hints from the environment, used when the API doesn't report limits
        /// (many OpenAI-compatible servers omit context/output fields from `/v1/models`).
        public var contextTokens: Int?
        public var maxOutputTokens: Int?

        public init(
            baseURL: URL, apiKey: String, model: String,
            contextTokens: Int? = nil, maxOutputTokens: Int? = nil
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.contextTokens = contextTokens
            self.maxOutputTokens = maxOutputTokens
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
            return Config(
                baseURL: url, apiKey: key, model: env["OPENAI_MODEL"] ?? "gpt-4o-mini",
                contextTokens: env["OPENAI_CONTEXT_TOKENS"].flatMap { Int($0) },
                maxOutputTokens: env["OPENAI_MAX_OUTPUT_TOKENS"].flatMap { Int($0) })
        }
    }

    let config: Config
    let session: URLSession
    let onUsage: (@Sendable (Usage) -> Void)?

    public init(
        config: Config,
        session: URLSession = .shared,
        onUsage: (@Sendable (Usage) -> Void)? = nil
    ) {
        self.config = config
        self.session = session
        self.onUsage = onUsage
    }

    public func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        let system = arguments.systemPrompt
        let user: String
        if case .string(let s)? = arguments.message { user = s } else { user = "" }
        let (content, toolCalls) = try await chat(
            system: system, user: user,
            tools: arguments.tools,
            temperature: arguments.temperature,
            maxTokens: arguments.maxTokens)
        if config.outputTypeName == ModelTurn.outputTypeName {
            // A ModelTurn may legitimately be empty — a stalled or token-truncated turn. Return it
            // so an agent loop can decide how to handle a dead turn, rather than aborting the run.
            return try JSONEncoder().encode(ModelTurn(reply: content, toolCalls: toolCalls))
        }
        // Plain-text output must carry text.
        guard let content else { throw OpenAIChatExecutorError.emptyResponse }
        return try JSONEncoder().encode(content)
    }

    // MARK: - Capabilities

    /// Resolve the model's limits: prefer values the API reports, then environment hints on the
    /// ``Config``, then ``ModelCapabilities/default``. Best-effort and never throws — a server that
    /// omits capability fields (the common case) simply falls through to the configured defaults.
    public func fetchCapabilities() async -> ModelCapabilities {
        let api = await fetchModelInfo()
        // API report → env hint → known-model heuristic → conservative default.
        let context = api.contextTokens
            ?? config.contextTokens
            ?? ModelCapabilities.knownContextWindow(forModelID: config.model)
            ?? ModelCapabilities.default.contextTokens
        let output = api.maxOutputTokens ?? config.maxOutputTokens ?? ModelCapabilities.default.maxOutputTokens
        // Output can never exceed the context window.
        return ModelCapabilities(contextTokens: context, maxOutputTokens: min(output, context))
    }

    /// Best-effort `GET /v1/models`: find this model's entry and read whatever capability fields the
    /// server exposes. Servers vary wildly, so we probe the common key spellings and tolerate their
    /// absence. Returns `(nil, nil)` on any error.
    private func fetchModelInfo() async -> (contextTokens: Int?, maxOutputTokens: Int?) {
        let contextKeys = ["context_length", "max_context_length", "max_model_len",
                           "context_window", "max_context", "n_ctx"]
        let outputKeys = ["max_output_tokens", "max_completion_tokens", "max_tokens"]
        var req = URLRequest(url: config.baseURL.appendingPathComponent("models"))
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard
            let (data, response) = try? await session.data(for: req),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["data"] as? [[String: Any]],
            let entry = entries.first(where: { $0["id"] as? String == config.model }) ?? entries.first
        else { return (nil, nil) }
        func firstInt(_ keys: [String]) -> Int? {
            for key in keys { if let value = entry[key] as? Int, value > 0 { return value } }
            return nil
        }
        return (firstInt(contextKeys), firstInt(outputKeys))
    }

    // MARK: - Wire types (request)

    private struct RequestMessage: Encodable { let role: String; let content: String }

    /// One entry in the OpenAI `tools` array: `{type:"function", function:{name, description, parameters}}`.
    private struct ToolWire: Encodable {
        let type = "function"
        let function: Function
        struct Function: Encodable {
            let name: String
            let description: String
            let parameters: JSONSchemaWire
        }
        init(_ d: ToolDescriptor) {
            function = Function(name: d.name, description: d.description,
                                parameters: JSONSchemaWire(d.inputSchema))
        }
    }

    /// Encodes a `PipelineAST.JSONSchema` as a standard JSON Schema object for tool parameters.
    private struct JSONSchemaWire: Encodable {
        let schema: JSONSchema
        init(_ schema: JSONSchema) { self.schema = schema }

        private enum K: String, CodingKey { case type, properties, required, items, oneOf }
        private struct DynamicKey: CodingKey {
            let stringValue: String; var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            switch schema {
            case .object(let properties, let required):
                var c = encoder.container(keyedBy: K.self)
                try c.encode("object", forKey: .type)
                var props = c.nestedContainer(keyedBy: DynamicKey.self, forKey: .properties)
                for (key, value) in properties {
                    try props.encode(JSONSchemaWire(value), forKey: DynamicKey(key))
                }
                if !required.isEmpty { try c.encode(required, forKey: .required) }
            case .array(let items):
                var c = encoder.container(keyedBy: K.self)
                try c.encode("array", forKey: .type)
                try c.encode(JSONSchemaWire(items), forKey: .items)
            case .string:  var c = encoder.container(keyedBy: K.self); try c.encode("string", forKey: .type)
            case .integer: var c = encoder.container(keyedBy: K.self); try c.encode("integer", forKey: .type)
            case .number:  var c = encoder.container(keyedBy: K.self); try c.encode("number", forKey: .type)
            case .boolean: var c = encoder.container(keyedBy: K.self); try c.encode("boolean", forKey: .type)
            case .any:
                var c = encoder.singleValueContainer(); try c.encode([String: String]())
            case .oneOf(let schemas):
                var c = encoder.container(keyedBy: K.self)
                try c.encode(schemas.map(JSONSchemaWire.init), forKey: .oneOf)
            }
        }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [RequestMessage]
        let tools: [ToolWire]?
        let temperature: Double?
        let maxTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, messages, tools, temperature
            case maxTokens = "max_tokens"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(messages, forKey: .messages)
            if let tools, !tools.isEmpty { try c.encode(tools, forKey: .tools) }
            if let t = temperature { try c.encode(t, forKey: .temperature) }
            if let m = maxTokens { try c.encode(m, forKey: .maxTokens) }
        }
    }

    // MARK: - Wire types (response)

    // `content` is optional: a turn may carry no text — a reasoning model truncated mid-thought
    // (`finish_reason: "length"`) or a tool-call-only response (`content: null` + `tool_calls`).
    private struct ChatResponse: Decodable {
        struct Choice: Decodable { let message: ResponseMessage }
        let choices: [Choice]
        let usage: UsageWire?
    }
    private struct UsageWire: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
    private struct ResponseMessage: Decodable {
        let content: String?
        let toolCalls: [ToolCallWire]?
        enum CodingKeys: String, CodingKey { case content; case toolCalls = "tool_calls" }
    }
    private struct ToolCallWire: Decodable {
        let id: String?
        let function: Function
        struct Function: Decodable { let name: String; let arguments: String }
    }

    // MARK: - HTTP

    private func chat(
        system: String,
        user: String,
        tools: [ToolDescriptor],
        temperature: Double?,
        maxTokens: Int?
    ) async throws -> (content: String?, toolCalls: [ToolCall]?) {
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
                tools: tools.isEmpty ? nil : tools.map(ToolWire.init),
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
        if let usage = decoded.usage {
            onUsage?(Usage(
                promptTokens: usage.promptTokens ?? 0,
                completionTokens: usage.completionTokens ?? 0,
                totalTokens: usage.totalTokens ?? 0))
        }
        guard let message = decoded.choices.first?.message else {
            throw OpenAIChatExecutorError.emptyResponse
        }
        let calls = message.toolCalls?.enumerated().map { index, wire in
            ToolCall(id: wire.id ?? "call_\(index)",
                     name: wire.function.name,
                     arguments: wire.function.arguments)
        }
        return (message.content, (calls?.isEmpty == false) ? calls : nil)
    }
}
