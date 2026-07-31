//
//  ModelArgumentCodingTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST

// Verifies that ModelArgument.custom encodes its JSONValue payload as Data so that
// binary-safe encoders (e.g. a binary Codable transport) cannot misread array bytes as
// a garbage string. Tests use JSONEncoder/JSONDecoder as a portable stand-in — the
// fix is in the encode/decode implementation, not the encoder transport.
final class ModelArgumentCodingTests: XCTestCase {

    private func roundTrip(_ argument: ModelArgument) throws -> ModelArgument {
        let data = try JSONEncoder().encode(argument)
        return try JSONDecoder().decode(ModelArgument.self, from: data)
    }

    func testCustomWithArrayJSONValueRoundTrips() throws {
        let original = ModelArgument.custom(
            key: "guardrailRules",
            value: .array([.string("illegal"), .string("harmful")])
        )
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    func testCustomWithStringJSONValueRoundTrips() throws {
        let original = ModelArgument.custom(key: "foo", value: .string("bar"))
        XCTAssertEqual(try roundTrip(original), original)
    }

    func testCustomWithObjectJSONValueRoundTrips() throws {
        let original = ModelArgument.custom(key: "meta", value: .object(["k": .integer(1)]))
        XCTAssertEqual(try roundTrip(original), original)
    }

    func testSystemPromptRoundTrips() throws {
        let original = ModelArgument.systemPrompt("Be concise.")
        XCTAssertEqual(try roundTrip(original), original)
    }

    func testTemperatureRoundTrips() throws {
        let original = ModelArgument.temperature(0.7)
        XCTAssertEqual(try roundTrip(original), original)
    }

    func testMaxTokensRoundTrips() throws {
        let original = ModelArgument.maxTokens(512)
        XCTAssertEqual(try roundTrip(original), original)
    }
}
