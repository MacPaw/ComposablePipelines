//
//  PipelineConstructionTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
@_spi(Internals) @testable import PipelineDSL

final class PipelineConstructionTests: XCTestCase {

    func testNestedPipeline_outerEmbedsInnerAsOneStep() {
        let outer = NestedPipelineFixture.OuterPipeline()
        let inner = NestedPipelineFixture.InnerPipeline()
        print("\(inner)\n")
        print("\(outer)\n")

        let outerGraph = outer.loweredGraph()
        let innerGraph = inner.loweredGraph()

        XCTAssertEqual(
            innerGraph,
            .sequence([
                .leaf(.opaque(typeName: "InnerA")),
                .leaf(.opaque(typeName: "InnerB")),
            ]),
            PipelineGraphTestHelpers.prettyPrint(innerGraph)
        )

        XCTAssertEqual(
            outerGraph,
            .sequence([
                .sequence([
                    .leaf(.opaque(typeName: "Prefix")),
                    .sequence([
                        .leaf(.opaque(typeName: "InnerA")),
                        .leaf(.opaque(typeName: "InnerB")),
                    ]),
                ]),
                .leaf(.opaque(typeName: "Suffix")),
            ]),
            PipelineGraphTestHelpers.prettyPrint(outerGraph)
        )
    }

    func testLinearSequence_leftAssociatedNesting() {
        print("\(LinearSequenceFixture.Linear())\n")
        let graph = LinearSequenceFixture.Linear().loweredGraph()

        let expected: PipelineGraph = .sequence([
            .sequence([
                .leaf(.opaque(typeName: "A")),
                .leaf(.opaque(typeName: "B")),
            ]),
            .leaf(.opaque(typeName: "C")),
        ])
        XCTAssertEqual(
            graph,
            expected,
            PipelineGraphTestHelpers.prettyPrint(graph)
        )
    }

    func testPipelineGraph_JSONCodable_roundTrip() throws {
        let graph: PipelineGraph = .sequence([
            .leaf(.opaque(typeName: "A")),
            .leaf(.opaque(typeName: "B")),
            .returnWith(.leaf(.just(valueTypeName: "String", jsonUTF8: "\"done\""))),
        ])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try graph.encoded(using: enc)
        XCTAssertEqual(try PipelineGraph.decode(from: data), graph)

        let linear = LinearSequenceFixture.Linear().loweredGraph()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let linearData = try linear.encoded(using: encoder)
        let decoded = try PipelineGraph.decode(from: linearData)
        XCTAssertEqual(decoded, linear)
    }

    func testModel_defaultLoweredGraphHasNoRequirements() {
        let graph = Model<String, String>(
            instructions: Just(value: "reply"),
            input: Just(value: "hello")
        ).pipelineGraph

        guard case let .leaf(.model(_, _, _, _, requirements)) = graph else {
            return XCTFail("Expected model leaf, got \(graph)")
        }
        XCTAssertNil(requirements)
    }

    func testModel_explicitRequirementsLowerIntoGraph() {
        let requirements = ModelSelectionRequirements(
            purpose: .textGeneration,
            backend: .custom("remote"),
            traits: [.quick, .lowCost],
            spec: .init(sourceID: "gpt-test", revision: "v1", additionalFiles: ["tokenizer.json"])
        )
        let graph = Model<String, String>(
            requirements: requirements,
            instructions: Just(value: "reply"),
            input: Just(value: "hello")
        ).pipelineGraph

        guard case let .leaf(.model(_, _, _, _, actual)) = graph else {
            return XCTFail("Expected model leaf, got \(graph)")
        }
        XCTAssertEqual(actual, requirements)
    }

    func testModelLeaf_JSONCodable_decodesLegacyGraphWithoutRequirements() throws {
        let graph: PipelineGraph = .leaf(.model(
            instructions: .leaf(.just(valueTypeName: "String", jsonUTF8: "\"reply\"")),
            tools: .empty,
            input: .leaf(.just(valueTypeName: "String", jsonUTF8: "\"hello\"")),
            outputTypeName: "String",
            requirements: .init(purpose: .chatCompletion)
        ))

        let encoded = try JSONEncoder().encode(graph)
        let legacyData = try dataByRemovingRequirements(from: encoded)
        let decoded = try PipelineGraph.decode(from: legacyData)

        guard case let .leaf(.model(_, _, _, _, requirements)) = decoded else {
            return XCTFail("Expected model leaf, got \(decoded)")
        }
        XCTAssertNil(requirements)
    }

    func testPipelineGraph_propertyList_roundTrip() throws {
        let original: PipelineGraph = .sequence([
            .leaf(.guardrail(rules: [.politics])),
            .leaf(.opaque(typeName: "X")),
        ])
        print("\(original)\n")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(original)
        let decoded = try PropertyListDecoder().decode(PipelineGraph.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEmptyBody_isEmptyGraph() {
        print("\(EmptyGraphFixture.EmptyBody())\n")
        let graph = EmptyGraphFixture.EmptyBody().loweredGraph()
        XCTAssertEqual(graph, .empty)
    }

    func testForEach_empty_lowersToEmpty() {
        XCTAssertEqual(ForEachFixture.Host(indices: []).loweredGraph(), .empty)
    }

    func testForEach_single_lowersWithoutSequenceWrapper() {
        XCTAssertEqual(
            ForEachFixture.Host(indices: [0]).loweredGraph(),
            .leaf(.opaque(typeName: "A"))
        )
    }

    func testForEach_multiple_lowersToFlatSequence() {
        let graph = ForEachFixture.Host(indices: [0, 1, 2]).loweredGraph()
        XCTAssertEqual(
            graph,
            .sequence([
                .leaf(.opaque(typeName: "A")),
                .leaf(.opaque(typeName: "A")),
                .leaf(.opaque(typeName: "A")),
            ]),
            PipelineGraphTestHelpers.prettyPrint(graph)
        )
    }

    func testSummarize_loweredGraph_isStructuredLeaf() {
        struct Host: Pipeline {
            typealias Output = String

            @State var docText: String = ""

            var body: some Pipeline {
                Summarize(text: $docText, maxTokens: 256)
            }
        }

        let host = Host()
        let bindingId = host.$docText.id
        let graph = host.loweredGraph()
        let expected: PipelineGraph = .leaf(
            .summarize(textBindingId: bindingId, textBindingValueType: "String", maxTokens: 256)
        )
        XCTAssertEqual(graph, expected, PipelineGraphTestHelpers.prettyPrint(graph))

        let pseudo = graph.pseudoSwiftDescription
        XCTAssertTrue(pseudo.contains("summarize(textBindingId:"), pseudo)
        XCTAssertTrue(pseudo.contains("valueType:"), pseudo)
        XCTAssertTrue(pseudo.contains(bindingId.uuidString), pseudo)
        XCTAssertTrue(pseudo.contains("String"), pseudo)
        XCTAssertTrue(pseudo.contains("256"), pseudo)
    }

    func testSummarizeLeaf_JSONCodable_roundTrip() throws {
        let chapterId = UUID(uuidString: "20000000-0000-4000-8000-00000000C0A1")!
        let graph: PipelineGraph = .sequence([
            .leaf(.summarize(textBindingId: chapterId, textBindingValueType: "String", maxTokens: 512)),
            .leaf(.opaque(typeName: "Footer")),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try graph.encoded(using: encoder)
        XCTAssertEqual(try PipelineGraph.decode(from: data), graph)
    }

    func testClientTask_loweredGraphWithClientActions_registersMatchingAction() async throws {
        struct Host: Pipeline {
            typealias Output = String

            var body: some Pipeline {
                ClientTask<String, String>(
                    input: { Just(value: "ping") },
                    action: { "\($0)-pong" }
                )
            }
        }

        let lowered = Host().loweredGraphWithClientActions()
        guard case let .leaf(.clientAction(taskID, _)) = lowered.graph else {
            return XCTFail("Expected clientAction, got \(PipelineGraphTestHelpers.prettyPrint(lowered.graph))")
        }
        guard let action = lowered.clientActions[taskID] else {
            return XCTFail("Expected registered action for \(taskID)")
        }

        let input = try JSONEncoder().encode("ping")
        let result = try await action(input)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "ping-pong")
    }

    func testModel_lowersToModelLeaf() {
        struct Host: Pipeline {
            typealias Output = String
            var body: some Pipeline {
                Model<String, String>(
                    instructions: "system instructions",
                    input: Just(value: "user text")
                )
            }
        }

        let graph = Host().loweredGraph()
        guard case let .leaf(.model(_, _, _, outputTypeName, _)) = graph else {
            return XCTFail("Expected model leaf, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertEqual(outputTypeName, "String")
    }

    func testClientTask_inlineLowering_registersClientActionPerInstance() {
        struct Host: Pipeline {
            typealias Output = String

            var body: some Pipeline {
                ClientTask {
                    "pong"
                }
            }
        }

        let first = Host().loweredGraphWithClientActions()
        let second = Host().loweredGraphWithClientActions()

        guard case let .leaf(.clientAction(firstTaskID, _)) = first.graph else {
            return XCTFail("Expected first clientAction, got \(PipelineGraphTestHelpers.prettyPrint(first.graph))")
        }
        guard case let .leaf(.clientAction(secondTaskID, _)) = second.graph else {
            return XCTFail("Expected second clientAction, got \(PipelineGraphTestHelpers.prettyPrint(second.graph))")
        }

        XCTAssertNotEqual(firstTaskID, secondTaskID, "Each lowering gets a fresh ClientTask.taskID")
        XCTAssertNotNil(first.clientActions[firstTaskID])
        XCTAssertNotNil(second.clientActions[secondTaskID])
    }

    // MARK: - Group DSL construction

    func testGroup_defaultParameters_sequentialTrue_gateFalse() {
        struct Host: Pipeline {
            typealias Output = String
            var body: some Pipeline {
                Group {
                    LinearSequenceFixture.A()
                    LinearSequenceFixture.B()
                }
            }
        }

        let graph = Host().loweredGraph()

        guard case let .group(sequential, gate, content) = graph else {
            return XCTFail("Expected .group, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertTrue(sequential, "Group default sequential should be true")
        XCTAssertFalse(gate, "Group default gate should be false")

        guard case let .sequence(items) = content else {
            return XCTFail("Expected .sequence content, got \(content)")
        }
        XCTAssertEqual(items.count, 2)
    }

    func testGroup_explicitGateTrue() {
        struct Host: Pipeline {
            typealias Output = String
            var body: some Pipeline {
                Group(gate: true) {
                    LinearSequenceFixture.A()
                }
            }
        }

        let graph = Host().loweredGraph()

        guard case let .group(sequential, gate, _) = graph else {
            return XCTFail("Expected .group, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertTrue(sequential)
        XCTAssertTrue(gate)
    }

    func testGroup_nonSequential() {
        struct Host: Pipeline {
            typealias Output = String
            var body: some Pipeline {
                Group(sequential: false) {
                    LinearSequenceFixture.A()
                    LinearSequenceFixture.B()
                }
            }
        }

        let graph = Host().loweredGraph()

        guard case let .group(sequential, gate, _) = graph else {
            return XCTFail("Expected .group, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertFalse(sequential)
        XCTAssertFalse(gate)
    }

    // MARK: - Group JSON round-trip

    func testGroup_JSONCodable_roundTrip() throws {
        let graph: PipelineGraph = .group(sequential: true, gate: true, .sequence([
            .leaf(.opaque(typeName: "A")),
            .leaf(.opaque(typeName: "B")),
        ]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try graph.encoded(using: encoder)
        XCTAssertEqual(try PipelineGraph.decode(from: data), graph)
    }

    // MARK: - Guardrail gated behavior

    func testGuardrail_defaultGated_wrapsInGroup() {
        struct Host: Pipeline {
            typealias Output = Bool
            var body: some Pipeline {
                Guardrail(rules: [.politics, .pii])
            }
        }

        let graph = Host().loweredGraph()

        guard case let .group(sequential, gate, content) = graph else {
            return XCTFail("Guardrail(gated: true) should produce .group, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertTrue(sequential, "Guardrail gate group should be sequential")
        XCTAssertTrue(gate, "Guardrail gate group should have gate=true")

        guard case let .leaf(leaf) = content else {
            return XCTFail("Expected .leaf inside group, got \(content)")
        }
        guard case let .guardrail(rules) = leaf else {
            return XCTFail("Expected .guardrail leaf, got \(leaf)")
        }
        XCTAssertEqual(rules, [.politics, .pii])
    }

    func testGuardrail_ungated_noGroupWrapper() {
        struct Host: Pipeline {
            typealias Output = Bool
            var body: some Pipeline {
                Guardrail(rules: [.pii], gated: false)
            }
        }

        let graph = Host().loweredGraph()

        guard case let .leaf(leaf) = graph else {
            return XCTFail("Guardrail(gated: false) should produce bare .leaf, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        guard case .guardrail = leaf else {
            return XCTFail("Expected .guardrail leaf, got \(leaf)")
        }
    }

    // MARK: - Control-flow read emission (read() injects stateGet at conditional boundary)

    func testRead_ifElse_injectsStateGetBeforeBranch() {
        struct Host: Pipeline {
            typealias Output = String
            @State var flag: String = ""

            var body: some Pipeline {
                $flag.set("value")
                if flag == "value" {
                    Model<String, String>(instructions: "yes", input: $flag.get())
                } else {
                    Model<String, String>(instructions: "no", input: $flag.get())
                }
            }
        }

        let host = Host()
        let graph = host.loweredGraph()

        func containsStateGet(_ node: PipelineGraph, slotID: UUID) -> Bool {
            switch node {
            case let .leaf(leaf):
                if case let .executionStateGet(id, _, _, _) = leaf { return id == slotID }
                return false
            case let .sequence(items):
                return items.contains { containsStateGet($0, slotID: slotID) }
            case let .group(_, _, content):
                return containsStateGet(content, slotID: slotID)
            default:
                return false
            }
        }

        XCTAssertTrue(
            containsStateGet(graph, slotID: host.$flag.id),
            "flag should inject a stateGet node.\nGraph: \(PipelineGraphTestHelpers.prettyPrint(graph))"
        )
    }

    func testRead_ifOnly_injectsStateGetBeforeBranch() {
        struct Host: Pipeline {
            typealias Output = String
            @State var flag: String = ""

            var body: some Pipeline {
                $flag.set("value")
                if flag == "value" {
                    Model<String, String>(instructions: "yes", input: $flag.get())
                }
            }
        }

        let host = Host()
        let graph = host.loweredGraph()

        func containsStateGet(_ node: PipelineGraph, slotID: UUID) -> Bool {
            switch node {
            case let .leaf(leaf):
                if case let .executionStateGet(id, _, _, _) = leaf { return id == slotID }
                return false
            case let .sequence(items):
                return items.contains { containsStateGet($0, slotID: slotID) }
            case let .group(_, _, content):
                return containsStateGet(content, slotID: slotID)
            default:
                return false
            }
        }

        XCTAssertTrue(
            containsStateGet(graph, slotID: host.$flag.id),
            "flag should inject a stateGet node for if-without-else.\nGraph: \(PipelineGraphTestHelpers.prettyPrint(graph))"
        )
    }

    func testNoRead_noInjectedStateGet() {
        struct Host: Pipeline {
            typealias Output = String
            @State var flag: String = ""

            var body: some Pipeline {
                $flag.set("value")
                Model<String, String>(instructions: "always", input: Just(value: flag))
            }
        }

        let host = Host()
        let graph = host.loweredGraph()

        /// Counts stateGet nodes that are direct children of sequences (i.e., injected
        /// by GraphEmissionContext), not those nested inside model/summarize subgraphs.
        func countInjectedStateGets(_ node: PipelineGraph, slotID: UUID) -> Int {
            switch node {
            case let .leaf(leaf):
                if case let .executionStateGet(id, _, _, _) = leaf, id == slotID { return 1 }
                return 0
            case let .sequence(items):
                return items.reduce(0) { $0 + countInjectedStateGets($1, slotID: slotID) }
            case let .group(_, _, content):
                return countInjectedStateGets(content, slotID: slotID)
            default:
                return 0
            }
        }

        let injectedCount = countInjectedStateGets(graph, slotID: host.$flag.id)
        XCTAssertEqual(injectedCount, 0,
            "No flag was called — no injected stateGet should appear.\nGraph: \(PipelineGraphTestHelpers.prettyPrint(graph))")
    }

    // MARK: - Group pseudo-Swift rendering

    func testGroup_pseudoSwift_rendersCorrectly() {
        let graph: PipelineGraph = .group(sequential: true, gate: true, .sequence([
            .leaf(.opaque(typeName: "A")),
            .leaf(.opaque(typeName: "B")),
        ]))

        let pseudo = graph.pseudoSwiftDescription
        XCTAssertTrue(pseudo.contains("Group(sequential, gate)"), "pseudo: \(pseudo)")
        XCTAssertTrue(pseudo.contains("A()"), "pseudo: \(pseudo)")
        XCTAssertTrue(pseudo.contains("B()"), "pseudo: \(pseudo)")
    }

    func testGroup_pseudoSwift_noFlags() {
        let graph: PipelineGraph = .group(sequential: false, gate: false, .leaf(.opaque(typeName: "X")))

        let pseudo = graph.pseudoSwiftDescription
        XCTAssertTrue(pseudo.contains("Group {"), "pseudo: \(pseudo)")
        XCTAssertFalse(pseudo.contains("sequential"), "pseudo: \(pseudo)")
        XCTAssertFalse(pseudo.contains("gate"), "pseudo: \(pseudo)")
    }

    private func dataByRemovingRequirements(from data: Data) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data)
        removeRequirements(from: &object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func removeRequirements(from object: inout Any) {
        if var dictionary = object as? [String: Any] {
            dictionary.removeValue(forKey: "requirements")
            for key in dictionary.keys {
                var value = dictionary[key] as Any
                removeRequirements(from: &value)
                dictionary[key] = value
            }
            object = dictionary
            return
        }

        if var array = object as? [Any] {
            for index in array.indices {
                var value = array[index]
                removeRequirements(from: &value)
                array[index] = value
            }
            object = array
        }
    }
}
