//
//  DelegationToolTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import ComposablePipelines
@testable import DelegateAgent

/// ``DelegationTool`` — the control tool a model calls to split its own work and grant each subagent
/// its slice.
///
/// Two properties matter and both are asserted throughout: the decoder survives everything a small
/// local model does to well-formed JSON, and a grant is always a **subset** of the published menu.
final class DelegationToolTests: XCTestCase {

    // MARK: - Fixtures

    private func tool(_ name: String) -> ToolDescriptor {
        ToolDescriptor(name: name, description: "does \(name)", inputSchema: .object(properties: [:]))
    }

    private func item(_ value: String) -> ContextItem {
        ContextItem(kind: .custom("note"), source: "test", value: .string(value))
    }

    private var menu: DelegationMenu {
        DelegationMenu(
            tools: [tool("get_weather"), tool("convert_currency"), tool("web_search")],
            context: ["memory": [item("remembered")], "docs": [item("doc-a"), item("doc-b")]]
        )
    }

    private func turn(arguments: String, reply: String? = nil) -> ModelTurn {
        ModelTurn(
            reply: reply,
            toolCalls: [ToolCall(id: "1", name: DelegationTool.name, arguments: arguments)]
        )
    }

    // MARK: - Descriptor

    func testDescriptorPublishesTheWholeMenu() {
        let descriptor = DelegationTool.descriptor(menu: menu)
        XCTAssertEqual(descriptor.name, DelegationTool.name)
        for name in menu.toolNames {
            XCTAssertTrue(descriptor.description.contains(name), "tool '\(name)' must be offered")
        }
        for label in menu.contextLabels {
            XCTAssertTrue(descriptor.description.contains(label), "label '\(label)' must be offered")
        }
    }

    func testDescriptorSchemaRequiresOnlyTheInstruction() {
        guard case let .object(properties, required) = DelegationTool.descriptor(menu: menu).inputSchema,
              case let .array(subtask) = properties["subtasks"],
              case let .object(fields, subtaskRequired) = subtask else {
            return XCTFail("expected subtasks: [ { … } ]")
        }
        XCTAssertEqual(required, ["subtasks"])
        XCTAssertEqual(Set(fields.keys), ["instruction", "tools", "context"])
        XCTAssertEqual(subtaskRequired, ["instruction"],
                       "grants are optional: a subagent with no tools still answers from knowledge")
    }

    func testDescriptionSurvivesAnEmptyMenu() {
        let descriptor = DelegationTool.descriptor(menu: DelegationMenu())
        XCTAssertTrue(descriptor.description.contains("(none)"))
        XCTAssertTrue(descriptor.description.contains("(no shareable context)"))
    }

    // MARK: - Decoding: the happy path

    func testBriefsCarryPerSubtaskToolAndContextGrants() {
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [
              {"instruction": "Weather in Kyiv", "tools": ["get_weather"], "context": ["memory"]},
              {"instruction": "100 USD to EUR", "tools": ["convert_currency"]}
            ]}
            """), menu: menu)

        XCTAssertEqual(briefs.count, 2)
        XCTAssertEqual(briefs[0].instruction, "Weather in Kyiv")
        XCTAssertEqual(briefs[0].toolNames, ["get_weather"])
        XCTAssertEqual(briefs[0].contextItems, [item("remembered")])
        XCTAssertEqual(briefs[1].toolNames, ["convert_currency"])
        XCTAssertEqual(briefs[1].contextItems, [], "a subtask that asked for no context gets none")
    }

    func testMultipleContextLabelsConcatenateInRequestOrder() {
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [{"instruction": "Summarize", "context": ["docs", "memory"]}]}
            """), menu: menu)
        XCTAssertEqual(briefs.first?.contextItems, [item("doc-a"), item("doc-b"), item("remembered")])
    }

    func testNoDelegationCallMeansAnswerDirectly() {
        let direct = ModelTurn(reply: "A monad is a monoid in the category of endofunctors.")
        XCTAssertEqual(DelegationTool.briefs(from: direct, menu: menu), [])
    }

    func testACallToADifferentToolIsNotADelegation() {
        let other = ModelTurn(toolCalls: [ToolCall(id: "1", name: "get_weather", arguments: "{}")])
        XCTAssertEqual(DelegationTool.briefs(from: other, menu: menu), [])
    }

    // MARK: - Decoding: what small local models actually emit

    func testTolerateAChainOfThoughtPreambleAroundTheArguments() {
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            <think>The user wants two things, so I should split this up.</think>
            {"subtasks": [{"instruction": "Weather in Kyiv", "tools": ["get_weather"]}]}
            """), menu: menu)
        XCTAssertEqual(briefs.map(\.instruction), ["Weather in Kyiv"])
    }

    func testTolerateExtraKeysTheModelInvents() {
        // A strict dictionary decode fails the whole parse the moment an unexpected key appears, which
        // would silently drop the delegation entirely.
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"reasoning": "two parts", "confidence": 0.9, "subtasks": [
              {"instruction": "Weather in Kyiv", "tools": ["get_weather"], "priority": 1}
            ]}
            """), menu: menu)
        XCTAssertEqual(briefs.map(\.instruction), ["Weather in Kyiv"])
        XCTAssertEqual(briefs.first?.toolNames, ["get_weather"])
    }

    // MARK: - Decoding: a split written out instead of called

    func testRecoverABareSubtaskArrayFromTheReply() {
        // Observed in practice: the model writes the split as text and never calls the
        // tool. The decision is right and only the envelope is missing.
        let turn = ModelTurn(reply: """
            [{ "instruction": "Generate a random password of 24 characters",
               "tools": ["get_weather"], "context": "memory" }]
            """)
        let briefs = DelegationTool.briefs(from: turn, menu: menu)
        XCTAssertEqual(briefs.map(\.instruction), ["Generate a random password of 24 characters"])
        XCTAssertEqual(briefs.first?.toolNames, ["get_weather"])
    }

    func testRecoverAFullArgumentsObjectFromTheReply() {
        let turn = ModelTurn(reply: """
            I'll split this up:
            {"subtasks": [{"instruction": "Weather in Kyiv", "tools": ["get_weather"]}]}
            """)
        XCTAssertEqual(DelegationTool.briefs(from: turn, menu: menu).map(\.instruction), ["Weather in Kyiv"])
    }

    func testASplitSketchedInsideReasoningIsNotADecision() {
        // The model drafts and discards splits while thinking. Only what it commits to past `</think>`
        // counts, or every abandoned draft would become a fan-out.
        let turn = ModelTurn(reply: """
            <think>Maybe [{"instruction": "Weather in Kyiv", "tools": ["get_weather"]}] — no, I know this \
            already.</think>
            The sky is blue because of Rayleigh scattering.
            """)
        XCTAssertEqual(DelegationTool.briefs(from: turn, menu: menu), [])
    }

    func testAPlainReplyStillMeansAnswerDirectly() {
        let turn = ModelTurn(reply: "RAII stands for Resource Acquisition Is Initialization.")
        XCTAssertEqual(DelegationTool.briefs(from: turn, menu: menu), [])
    }

    func testARealToolCallWinsOverProse() {
        let turn = ModelTurn(
            reply: #"[{"instruction": "From the reply", "tools": []}]"#,
            toolCalls: [ToolCall(id: "1", name: DelegationTool.name,
                                 arguments: #"{"subtasks":[{"instruction":"From the call"}]}"#)]
        )
        XCTAssertEqual(DelegationTool.briefs(from: turn, menu: menu).map(\.instruction), ["From the call"])
    }

    func testTolerateAScalarWhereAListWasAsked() {
        // Observed in practice: the model writes `"context": "the city"` rather than a
        // list. Before this was tolerated, one scalar in one optional field failed the whole `Arguments`
        // decode and threw away the delegation entire — instruction and tools included, both correct.
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [
              {"instruction": "Weather in Kyiv", "tools": "get_weather", "context": "the user's city"}
            ]}
            """), menu: menu)
        XCTAssertEqual(briefs.map(\.instruction), ["Weather in Kyiv"])
        XCTAssertEqual(briefs.first?.toolNames, ["get_weather"])
        // The scalar context is prose, not a menu label, so it grants nothing — but it no longer costs
        // the delegation.
        XCTAssertEqual(briefs.first?.contextItems, [])
    }

    func testAScalarContextStillClampsToTheMenu() {
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [{"instruction": "Weather in Kyiv", "context": "memory"}]}
            """), menu: menu)
        XCTAssertEqual(briefs.first?.contextItems, menu.context["memory"] ?? [])
    }

    func testATypeNeitherStringNorListGrantsNothingRatherThanFailing() {
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [{"instruction": "Weather in Kyiv", "tools": 7, "context": {"a": 1}}]}
            """), menu: menu)
        XCTAssertEqual(briefs.map(\.instruction), ["Weather in Kyiv"])
        XCTAssertEqual(briefs.first?.toolNames, [])
    }

    func testTolerateTrailingCommentaryAfterTheJSON() {
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [{"instruction": "Weather in Kyiv"}]}
            I will now hand this to my specialist.
            """), menu: menu)
        XCTAssertEqual(briefs.map(\.instruction), ["Weather in Kyiv"])
    }

    func testUnparseableArgumentsYieldNoBriefs() {
        XCTAssertEqual(DelegationTool.briefs(from: turn(arguments: "I'll delegate this"), menu: menu), [])
        XCTAssertEqual(DelegationTool.briefs(from: turn(arguments: "{not json}"), menu: menu), [])
    }

    // MARK: - Decoding: clamping to the menu

    func testInventedToolNamesAreDropped() {
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [{"instruction": "Do it", "tools": ["get_weather", "launch_missiles"]}]}
            """), menu: menu)
        XCTAssertEqual(briefs.first?.toolNames, ["get_weather"],
                       "a grant can only ever be a subset of the published menu")
    }

    func testUnknownContextLabelsAreDropped() {
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [{"instruction": "Do it", "context": ["memory", "secrets"]}]}
            """), menu: menu)
        XCTAssertEqual(briefs.first?.contextItems, [item("remembered")])
    }

    func testGrantedToolsFollowMenuOrderNotRequestOrder() {
        // Prompt order biases a small model's choice, so the model must not be able to reorder the
        // catalog it is shown.
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [{"instruction": "Do it",
                           "tools": ["web_search", "convert_currency", "get_weather"]}]}
            """), menu: menu)
        XCTAssertEqual(briefs.first?.toolNames, ["get_weather", "convert_currency", "web_search"])
    }

    func testDuplicateRequestedToolsAreGrantedOnce() {
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [{"instruction": "Do it", "tools": ["get_weather", "get_weather"]}]}
            """), menu: menu)
        XCTAssertEqual(briefs.first?.toolNames, ["get_weather"])
    }

    func testBlankInstructionsAreDropped() {
        // A subagent with nothing to do still costs a spawn slot out of the shared budget.
        let briefs = DelegationTool.briefs(from: turn(arguments: """
            {"subtasks": [{"instruction": "   "}, {"instruction": "Real work"}]}
            """), menu: menu)
        XCTAssertEqual(briefs.map(\.instruction), ["Real work"])
    }

    func testEmptySubtaskListMeansAnswerDirectly() {
        XCTAssertEqual(DelegationTool.briefs(from: turn(arguments: #"{"subtasks": []}"#), menu: menu), [])
    }

    // MARK: - Execution

    /// Records whether it ran, so a rejected call can be proven *not* to have executed.
    private final class SpyTool: ToolExecutor, @unchecked Sendable {
        let descriptor: ToolDescriptor
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        init(name: String) {
            descriptor = ToolDescriptor(name: name, description: "spy", inputSchema: .object(properties: [:]))
        }

        func callJSON(_ inputJSON: Data) async throws -> Data {
            lock.withLock { calls += 1 }
            return try JSONEncoder().encode("\(descriptor.name) ran")
        }
    }

    private func call(_ name: String) -> ModelTurn {
        ModelTurn(toolCalls: [ToolCall(id: "1", name: name, arguments: "{}")])
    }

    func testResolveRunsAGrantedTool() async {
        let weather = SpyTool(name: "get_weather")
        let brief = DelegateBrief(instruction: "Weather", toolNames: ["get_weather"])
        let text = await DelegationTool.resolve(turn: call("get_weather"), brief: brief, tools: [weather])
        XCTAssertEqual(text, "get_weather ran")
        XCTAssertEqual(weather.callCount, 1)
    }

    func testResolveRefusesAToolOutsideTheBriefWithoutRunningIt() async {
        // The second enforcement point: narrowing stops the model *choosing* a foreign tool, this stops
        // a hallucinated name from *landing*.
        let currency = SpyTool(name: "convert_currency")
        let brief = DelegateBrief(instruction: "Weather", toolNames: ["get_weather"])
        let text = await DelegationTool.resolve(
            turn: call("convert_currency"), brief: brief, tools: [currency])
        XCTAssertTrue(text.contains("not available"))
        XCTAssertTrue(text.contains("get_weather"), "the refusal tells the model what it may use")
        XCTAssertEqual(currency.callCount, 0, "a tool outside the brief must never execute")
    }

    func testResolveRefusesEveryToolWhenTheBriefGrantedNone() async {
        let weather = SpyTool(name: "get_weather")
        let brief = DelegateBrief(instruction: "Think", toolNames: [])
        let text = await DelegationTool.resolve(turn: call("get_weather"), brief: brief, tools: [weather])
        XCTAssertTrue(text.contains("Available: none"))
        XCTAssertEqual(weather.callCount, 0)
    }

    func testResolveReturnsTheDistilledReplyWhenNoToolWasCalled() async {
        let turn = ModelTurn(reply: "<think>hmm</think>The answer is 42.")
        let text = await DelegationTool.resolve(
            turn: turn, brief: DelegateBrief(instruction: "Answer"), tools: [])
        XCTAssertEqual(text, "The answer is 42.", "chain-of-thought never reaches the parent")
    }

    func testResolveKeepsThePreambleAlongsideTheToolResult() async {
        let weather = SpyTool(name: "get_weather")
        let turn = ModelTurn(
            reply: "Let me check that.",
            toolCalls: [ToolCall(id: "1", name: "get_weather", arguments: "{}")]
        )
        let brief = DelegateBrief(instruction: "Weather", toolNames: ["get_weather"])
        let text = await DelegationTool.resolve(turn: turn, brief: brief, tools: [weather])
        XCTAssertEqual(text, "Let me check that.\n\nget_weather ran")
    }

    func testResolveTurnsAFailingToolIntoReadableText() async {
        struct Boom: ToolExecutor {
            let descriptor = ToolDescriptor(
                name: "boom", description: "fails", inputSchema: .object(properties: [:]))
            func callJSON(_ inputJSON: Data) async throws -> Data {
                throw NSError(domain: "test", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "exploded"])
            }
        }
        let brief = DelegateBrief(instruction: "Try", toolNames: ["boom"])
        let text = await DelegationTool.resolve(turn: call("boom"), brief: brief, tools: [Boom()])
        XCTAssertTrue(text.contains("boom"))
        XCTAssertTrue(text.contains("exploded"), "one bad call must not abort the subagent")
    }
}
