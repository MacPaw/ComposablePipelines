//
//  DelegationParallelCallsTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import ComposablePipelines
@testable import DelegateAgent
import PipelineAST

/// A subagent turn carrying **several** tool calls.
///
/// `ToolCallTextRecovery` splits a Pythonic block into its individual calls, so the parser hands the
/// consumer N of them. `resolve` used to keep only the first: the rest were neither executed nor
/// reported back as text, leaving the model no way to notice that what it asked for never happened.
final class DelegationParallelCallsTests: XCTestCase {

    /// Records whether it ran, so a rejected call can be proven *not* to have executed.
    private final class SpyTool: ToolExecutor, @unchecked Sendable {
        let descriptor: ToolDescriptor
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        init(_ name: String) {
            descriptor = ToolDescriptor(name: name, description: "spy", inputSchema: .object(properties: [:]))
        }

        func callJSON(_ inputJSON: Data) async throws -> Data {
            lock.withLock { calls += 1 }
            return try JSONEncoder().encode("\(descriptor.name) ran")
        }
    }

    private func turn(calling names: [String], reply: String? = nil) -> ModelTurn {
        ModelTurn(
            reply: reply,
            toolCalls: names.enumerated().map {
                ToolCall(id: "\($0.offset)", name: $0.element, arguments: "{}")
            }
        )
    }

    func testEveryGrantedCallRunsInTheOrderTheModelWroteThem() async {
        let weather = SpyTool("get_weather")
        let currency = SpyTool("convert_currency")
        let brief = DelegateBrief(instruction: "Both", toolNames: ["get_weather", "convert_currency"])

        let text = await DelegationTool.resolve(
            turn: turn(calling: ["get_weather", "convert_currency"]),
            brief: brief,
            tools: [weather, currency]
        )

        XCTAssertEqual(text, "get_weather ran\n\nconvert_currency ran")
        XCTAssertEqual(weather.callCount, 1)
        XCTAssertEqual(currency.callCount, 1, "the second call must not be dropped")
    }

    func testARefusedCallDoesNotAbortTheOnesBesideIt() async {
        let weather = SpyTool("get_weather")
        let currency = SpyTool("convert_currency")
        let brief = DelegateBrief(instruction: "Weather", toolNames: ["get_weather"])

        let text = await DelegationTool.resolve(
            turn: turn(calling: ["convert_currency", "get_weather"]),
            brief: brief,
            tools: [weather, currency]
        )

        XCTAssertTrue(text.contains("not available"), "the refusal is text the model can read")
        XCTAssertTrue(text.contains("get_weather ran"), "a refusal must not abort the remaining calls")
        XCTAssertEqual(currency.callCount, 0, "a tool outside the brief still never executes")
        XCTAssertEqual(weather.callCount, 1)
    }

    func testThePreambleStaysAheadOfEveryResult() async {
        let weather = SpyTool("get_weather")
        let currency = SpyTool("convert_currency")
        let brief = DelegateBrief(instruction: "Both", toolNames: ["get_weather", "convert_currency"])

        let text = await DelegationTool.resolve(
            turn: turn(calling: ["get_weather", "convert_currency"], reply: "Checking both."),
            brief: brief,
            tools: [weather, currency]
        )

        XCTAssertEqual(text, "Checking both.\n\nget_weather ran\n\nconvert_currency ran")
    }
}
