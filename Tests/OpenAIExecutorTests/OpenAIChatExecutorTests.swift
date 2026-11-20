//
//  OpenAIChatExecutorTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLProtocol / URLSession live here on Linux
#endif
import PipelineAST
@testable import OpenAIExecutor

/// Thread-safe capture for the `@Sendable` usage callback.
private final class UsageBox: @unchecked Sendable {
    private let lock = Lock()
    private var value: Usage?
    var last: Usage? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ usage: Usage) { lock.lock(); value = usage; lock.unlock() }
}

final class OpenAIChatExecutorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequestBody = nil
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequestBody = nil
        super.tearDown()
    }

    func testConfig_missingKey_throws() {
        XCTAssertThrowsError(try OpenAIChatExecutor.Config.fromEnvironment([:])) { error in
            XCTAssertEqual(error as? OpenAIChatExecutorError, .missingAPIKey)
        }
    }

    func testConfig_defaults_whenOnlyKeyPresent() throws {
        let c = try OpenAIChatExecutor.Config.fromEnvironment(["OPENAI_API_KEY": "k"])
        XCTAssertEqual(c.baseURL.absoluteString, "https://api.openai.com/v1")
        XCTAssertEqual(c.model, "gpt-4o-mini")
        XCTAssertEqual(c.apiKey, "k")
    }
}

// MARK: - StubURLProtocol

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequestBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            Self.lastRequestBody = data
        } else { Self.lastRequestBody = request.httpBody }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "StubURLProtocol", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No handler set for StubURLProtocol"]))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - runModel tests

extension OpenAIChatExecutorTests {
    private func stubbedExecutor(
        contextTokens: Int? = nil, maxOutputTokens: Int? = nil
    ) -> OpenAIChatExecutor {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let config = OpenAIChatExecutor.Config(
            baseURL: URL(string: "https://example.test/v1")!, apiKey: "k", model: "m",
            contextTokens: contextTokens, maxOutputTokens: maxOutputTokens)
        return OpenAIChatExecutor(config: config, session: session)
    }

    // MARK: - Capabilities

    func testConfig_readsCapabilityEnv() throws {
        let c = try OpenAIChatExecutor.Config.fromEnvironment([
            "OPENAI_API_KEY": "k", "OPENAI_CONTEXT_TOKENS": "262144", "OPENAI_MAX_OUTPUT_TOKENS": "8192"])
        XCTAssertEqual(c.contextTokens, 262_144)
        XCTAssertEqual(c.maxOutputTokens, 8_192)
    }

    func testFetchCapabilities_readsFromModelsList() async {
        StubURLProtocol.handler = { req in
            let body = Data(#"{"object":"list","data":[{"id":"m","context_length":262144,"max_output_tokens":8192}]}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let caps = await stubbedExecutor().fetchCapabilities()
        XCTAssertEqual(caps.contextTokens, 262_144)
        XCTAssertEqual(caps.maxOutputTokens, 8_192)
    }

    func testFetchCapabilities_fallsBackToConfigWhenServerOmitsThem() async {
        // Server returns the bare spec (no capability fields) — the Config/env hint wins.
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"object":"list","data":[{"id":"m","object":"model"}]}"#.utf8))
        }
        let caps = await stubbedExecutor(contextTokens: 262_144, maxOutputTokens: 8_192).fetchCapabilities()
        XCTAssertEqual(caps.contextTokens, 262_144)
        XCTAssertEqual(caps.maxOutputTokens, 8_192)
    }

    func testRunModel_reportsServerUsage() async throws {
        StubURLProtocol.handler = { req in
            let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":123,"completion_tokens":45,"total_tokens":168}}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let box = UsageBox()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let exec = OpenAIChatExecutor(
            config: .init(baseURL: URL(string: "https://example.test/v1")!, apiKey: "k", model: "m"),
            session: session, onUsage: { box.set($0) })
        _ = try await exec.runModel(
            config: ModelConfig(outputTypeName: "String"),
            arguments: ["message": .message(.string("u"))], onDelta: nil)
        XCTAssertEqual(box.last?.promptTokens, 123)
        XCTAssertEqual(box.last?.completionTokens, 45)
        XCTAssertEqual(box.last?.totalTokens, 168)
    }

    func testFetchCapabilities_infersKnownModelWindow() async {
        // Server omits capability fields and no env hint is set — infer from the model id.
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"object":"list","data":[{"id":"mlx-community/gemma-4-26b-a4b-it-4bit"}]}"#.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let exec = OpenAIChatExecutor(
            config: .init(baseURL: URL(string: "https://example.test/v1")!, apiKey: "k",
                          model: "mlx-community/gemma-4-26b-a4b-it-4bit"),
            session: session)
        let caps = await exec.fetchCapabilities()
        XCTAssertEqual(caps.contextTokens, 262_144)
    }

    func testKnownContextWindow_matchesFamilies() {
        XCTAssertEqual(ModelCapabilities.knownContextWindow(forModelID: "mlx-community/gemma-4-26b-a4b-it-4bit"), 262_144)
        XCTAssertEqual(ModelCapabilities.knownContextWindow(forModelID: "google/gemma-3-12b"), 131_072)
        XCTAssertNil(ModelCapabilities.knownContextWindow(forModelID: "some-unknown-model"))
    }

    func testFetchCapabilities_fallsBackToDefaultWhenNothingKnown() async {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"object":"list","data":[{"id":"m"}]}"#.utf8))
        }
        let caps = await stubbedExecutor().fetchCapabilities()
        XCTAssertEqual(caps.contextTokens, ModelCapabilities.default.contextTokens)
        XCTAssertEqual(caps.maxOutputTokens, ModelCapabilities.default.maxOutputTokens)
    }

    func testRunModel_postsChatCompletions_andReturnsReply() async throws {
        StubURLProtocol.handler = { req in
            let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"Hello there"}}]}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let exec = stubbedExecutor()
        let args: ModelArguments = [
            "systemPrompt": .systemPrompt("be nice"),
            "message": .message(.string("hi"))
        ]
        let result = try await exec.runModel(
            config: ModelConfig(outputTypeName: "String"),
            arguments: args,
            onDelta: nil)

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "Hello there")

        let sent = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try JSONSerialization.jsonObject(with: sent) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "m")
        let messages = json["messages"] as! [[String: String]]
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.map { $0["content"] }, ["be nice", "hi"])
        XCTAssertNil(json["temperature"], "temperature must be omitted when not set")
        XCTAssertNil(json["max_tokens"], "max_tokens must be omitted when not set")
    }

    /// A replayed tool exchange goes out as role-tagged messages the provider can pair up: the
    /// assistant turn carries its `tool_calls` (and no empty `content`), the result carries the
    /// matching `tool_call_id`, and an empty trailing message is not sent at all.
    ///
    /// - Author: Claude
    func testRunModel_priorTurns_sendsToolExchangeOnTheWire() async throws {
        StubURLProtocol.handler = { req in
            let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"done"}}]}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let args: ModelArguments = [
            "systemPrompt": .systemPrompt("sys"),
            "priorTurns": .priorTurns([
                ConversationTurn(role: "user", content: "Task: list"),
                ConversationTurn(role: "assistant", content: "", toolCalls: [
                    ToolCall(id: "c1", name: "list_dir", arguments: #"{"path":"."}"#),
                ]),
                ConversationTurn(role: "tool", content: "a.txt", toolCallID: "c1"),
            ]),
            "message": .message(.string("")),
        ]
        _ = try await stubbedExecutor().runModel(
            config: ModelConfig(outputTypeName: ModelTurn.outputTypeName), arguments: args, onDelta: nil)

        let sent = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])

        let assistant = messages[2]
        XCTAssertNil(assistant["content"], "an empty content next to tool_calls must be omitted")
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "c1")
        XCTAssertEqual(calls.first?["type"] as? String, "function")
        let function = try XCTUnwrap(calls.first?["function"] as? [String: String])
        XCTAssertEqual(function["name"], "list_dir")
        XCTAssertEqual(function["arguments"], #"{"path":"."}"#)

        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(messages[3]["content"] as? String, "a.txt")
    }

    func testRunModel_modelTurnOutput_wrapsReply() async throws {
        StubURLProtocol.handler = { req in
            let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"answer"}}]}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let args: ModelArguments = [
            "systemPrompt": .systemPrompt("sys"),
            "message": .message(.string("q"))
        ]
        let result = try await stubbedExecutor().runModel(
            config: ModelConfig(outputTypeName: ModelTurn.outputTypeName),
            arguments: args,
            onDelta: nil)
        let turn = try JSONDecoder().decode(ModelTurn.self, from: result)
        XCTAssertEqual(turn.reply, "answer")
        XCTAssertNil(turn.toolCalls)
    }

    func testRunModel_non2xx_throwsHTTPStatus() async {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":"nope"}"#.utf8))
        }
        let args: ModelArguments = [
            "systemPrompt": .systemPrompt("s"),
            "message": .message(.string("u"))
        ]
        do {
            _ = try await stubbedExecutor().runModel(
                config: ModelConfig(outputTypeName: "String"),
                arguments: args,
                onDelta: nil)
            XCTFail("expected throw")
        } catch let e as OpenAIChatExecutorError {
            guard case .httpStatus(401, _) = e else { return XCTFail("wrong error: \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    // A reasoning model truncated mid-thought (or a tool-call-only turn) returns a
    // `message` with no `content` key. That must surface as `.emptyResponse`, not a
    // raw `DecodingError` leaking the wire shape.
    func testRunModel_messageWithoutContent_throwsEmptyResponse() async {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"choices":[{"message":{"role":"assistant","reasoning":"…"}}]}"#.utf8))
        }
        let args: ModelArguments = [
            "systemPrompt": .systemPrompt("s"),
            "message": .message(.string("u"))
        ]
        do {
            _ = try await stubbedExecutor().runModel(
                config: ModelConfig(outputTypeName: "String"),
                arguments: args,
                onDelta: nil)
            XCTFail("expected throw")
        } catch let e as OpenAIChatExecutorError {
            guard case .emptyResponse = e else { return XCTFail("wrong error: \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    // A ModelTurn output must tolerate an empty turn (no content, no tool calls) — a stalled or
    // token-truncated turn is data the caller handles, not a fatal error.
    func testRunModel_emptyModelTurn_doesNotThrow() async throws {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"choices":[{"message":{"role":"assistant","reasoning":"…"}}]}"#.utf8))
        }
        let args: ModelArguments = [
            "systemPrompt": .systemPrompt("s"),
            "message": .message(.string("u"))
        ]
        let result = try await stubbedExecutor().runModel(
            config: ModelConfig(outputTypeName: ModelTurn.outputTypeName),
            arguments: args, onDelta: nil)
        let turn = try JSONDecoder().decode(ModelTurn.self, from: result)
        XCTAssertNil(turn.reply)
        XCTAssertNil(turn.toolCalls)
    }

    // MARK: - Tool calling

    func testRunModel_serializesToolsIntoRequest() async throws {
        StubURLProtocol.handler = { req in
            let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let descriptor = ToolDescriptor(
            name: "read_file",
            description: "Read a file",
            inputSchema: .object(properties: ["path": .string], required: ["path"]))
        let args: ModelArguments = [
            "systemPrompt": .systemPrompt("s"),
            "message": .message(.string("u")),
            "tools": .tools([descriptor])
        ]
        _ = try await stubbedExecutor().runModel(
            config: ModelConfig(outputTypeName: "String"), arguments: args, onDelta: nil)

        let sent = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try JSONSerialization.jsonObject(with: sent) as! [String: Any]
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(function["name"] as? String, "read_file")
        XCTAssertEqual(function["description"] as? String, "Read a file")
        let params = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "object")
        XCTAssertEqual(params["required"] as? [String], ["path"])
        let props = try XCTUnwrap(params["properties"] as? [String: Any])
        let pathSchema = try XCTUnwrap(props["path"] as? [String: Any])
        XCTAssertEqual(pathSchema["type"] as? String, "string")
    }

    /// The one converter every dictionary-based path uses: descriptions merge into the node they wrap,
    /// the outermost winning, and `required` is left out when empty unless asked for.
    ///
    /// - Author: Claude
    func testStandardObjectIsTheSharedConverter() {
        let schema = JSONSchema.object(properties: [
            "path": JSONSchema.string.described("A path"),
            "any": JSONSchema.any.described("inner").described("outer"),
            "tags": .array(items: JSONSchema.string.described("A tag")),
        ], required: [])
        let plain = schema.standardObject() as NSDictionary
        XCTAssertEqual(plain, [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "A path"],
                "any": ["description": "outer"],
                "tags": ["type": "array", "items": ["type": "string", "description": "A tag"]],
            ],
        ] as NSDictionary)
        XCTAssertEqual(schema.standardObject(includingEmptyRequired: true)["required"] as? [String], [])
    }

    /// Descriptions reach the wire at any depth; a nested one gives way to the outer one, and a
    /// described `.any` — single-value on the encoder — is no crash, nested or not.
    ///
    /// - Author: Claude
    func testRunModel_serializesDescribedParameters() async throws {
        StubURLProtocol.handler = { req in
            let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let descriptor = ToolDescriptor(
            name: "probe",
            description: "Probe",
            inputSchema: .object(properties: [
                "path": JSONSchema.string.described("A path"),
                "value": JSONSchema.any.described("inner").described("outer"),
                "count": JSONSchema.integer.described("inner").described("outer"),
            ], required: ["path"]))
        let args: ModelArguments = [
            "systemPrompt": .systemPrompt("s"),
            "message": .message(.string("u")),
            "tools": .tools([descriptor])
        ]
        _ = try await stubbedExecutor().runModel(
            config: ModelConfig(outputTypeName: "String"), arguments: args, onDelta: nil)

        let sent = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try JSONSerialization.jsonObject(with: sent) as! [String: Any]
        let function = try XCTUnwrap((json["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        let props = try XCTUnwrap((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        let path = try XCTUnwrap(props["path"] as? [String: Any])
        XCTAssertEqual(path["type"] as? String, "string")
        XCTAssertEqual(path["description"] as? String, "A path")
        let value = try XCTUnwrap(props["value"] as? [String: Any])
        XCTAssertEqual(value as NSDictionary, ["description": "outer"] as NSDictionary)
        let count = try XCTUnwrap(props["count"] as? [String: Any])
        XCTAssertEqual(count["type"] as? String, "integer")
        XCTAssertEqual(count["description"] as? String, "outer")
    }

    func testRunModel_parsesToolCallsIntoModelTurn() async throws {
        StubURLProtocol.handler = { req in
            let body = Data(#"""
            {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
              {"id":"abc","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"x.swift\"}"}}
            ]}}]}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let args: ModelArguments = [
            "systemPrompt": .systemPrompt("s"),
            "message": .message(.string("u"))
        ]
        // A tool-call-only turn (content null) must not throw .emptyResponse.
        let result = try await stubbedExecutor().runModel(
            config: ModelConfig(outputTypeName: ModelTurn.outputTypeName),
            arguments: args, onDelta: nil)
        let turn = try JSONDecoder().decode(ModelTurn.self, from: result)
        XCTAssertNil(turn.reply)
        let calls = try XCTUnwrap(turn.toolCalls)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "abc")
        XCTAssertEqual(calls[0].name, "read_file")
        XCTAssertEqual(calls[0].arguments, #"{"path":"x.swift"}"#)
    }
}
