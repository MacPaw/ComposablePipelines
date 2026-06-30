//
//  OpenAIChatExecutorTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
@testable import OpenAIExecutor

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
    private func stubbedExecutor() -> OpenAIChatExecutor {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let config = OpenAIChatExecutor.Config(
            baseURL: URL(string: "https://example.test/v1")!, apiKey: "k", model: "m")
        return OpenAIChatExecutor(config: config, session: session)
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
}
