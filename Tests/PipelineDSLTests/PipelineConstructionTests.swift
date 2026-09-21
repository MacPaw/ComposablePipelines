//
//  PipelineConstructionTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
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

    func testModel_defaultLoweredGraphUsesDefaultRequirements() {
        let graph = Model<String>().systemPrompt("reply").message("hello").pipelineGraph

        guard case let .leaf(.model(config, _)) = graph else {
            return XCTFail("Expected model leaf, got \(graph)")
        }
        XCTAssertEqual(config.traits, .textGeneration)
    }

    func testModel_explicitRequirementsLowerTraitsIntoGraph() {
        let requirements = ModelSelectionRequirements(
            backend: .custom("remote"),
            traits: [.textGeneration, .quick, .lowCost],
            spec: .init(sourceID: "gpt-test", revision: "v1", additionalFiles: ["tokenizer.json"])
        )
        let graph = Model<String>(requirements: requirements).systemPrompt("reply").message("hello").pipelineGraph

        guard case let .leaf(.model(config, _)) = graph else {
            return XCTFail("Expected model leaf, got \(graph)")
        }
        XCTAssertEqual(config.traits, requirements.traits)
    }

    func testModelLeaf_JSONCodable_roundTrip() throws {
        let config = ModelConfig(
            outputTypeName: "String",
            traits: [],
            streamingReplySlotID: nil,
            contextItemsSlotIDs: []
        )
        let graph: PipelineGraph = .leaf(.model(config: config, arguments: [
            "systemPrompt": .systemPrompt("reply"),
            "message": .message(.string("hello"))
        ]))

        let encoded = try JSONEncoder().encode(graph)
        let decoded = try PipelineGraph.decode(from: encoded)
        XCTAssertEqual(decoded, graph)
    }

    func testModelInputLeaf_JSONCodable_roundTrip() throws {
        let graph = Model<String>(traits: .memoryNormalization)
            .input {
                Model<String>(traits: .entityExtraction)
                    .input("hello")
            }
            .pipelineGraph

        let encoded = try JSONEncoder().encode(graph)
        let decoded = try PipelineGraph.decode(from: encoded)

        XCTAssertEqual(decoded, graph)
    }

    func testPipelineGraph_propertyList_roundTrip() throws {
        let original: PipelineGraph = .sequence([
            .leaf(.opaque(typeName: "PolicyCheck")),
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
                Model<String>().systemPrompt("system instructions").message("user text")
            }
        }

        let graph = Host().loweredGraph()
        guard case let .leaf(.model(config, _)) = graph else {
            return XCTFail("Expected model leaf, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertEqual(config.outputTypeName, "String")
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

    // MARK: - Composed guardrail

    func testGuardrailClassification_lowersToModelInputLeaf() {
        let graph = GuardrailClassification(
            "Contact me at alex@example.com",
            rules: [.illegal]
        ).pipelineGraph

        guard case let .leaf(.modelInput(config, arguments, query)) = graph else {
            return XCTFail("Expected modelInput leaf, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertEqual(config.outputTypeName, "Bool")
        XCTAssertTrue(config.traits.contains(.guardrailClassification))
        XCTAssertNotNil(arguments["guardrailRules"])
        guard case let .leaf(.just(valueTypeName, jsonUTF8)) = query else {
            return XCTFail("Expected constant string query input")
        }
        XCTAssertEqual(valueTypeName, "String")
        XCTAssertEqual(jsonUTF8, "\"Contact me at alex@example.com\"")
    }

    func testGuardrailClassification_emptyRules_lowersToAllowedConstant() {
        let graph = GuardrailClassification(
            "Hello",
            rules: []
        ).pipelineGraph

        guard case let .leaf(.just(valueTypeName, jsonUTF8)) = graph else {
            return XCTFail("Expected constant true, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertEqual(valueTypeName, "Bool")
        XCTAssertEqual(jsonUTF8, "true")
    }

    func testGuardrail_composesClassificationStateAndBranch() {
        let graph = Guardrail(
            "Hello",
            rules: [.illegal],
            allowed: { Just(value: "allowed") },
            blocked: { Just(value: "blocked") }
        ).loweredGraph()

        guard case let .sequence(items) = graph, items.count == 2 else {
            return XCTFail("Expected classification followed by a branch, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        guard case let .leaf(.executionStateSet(_, valueTypeName, value, "guardrailAllowed", .commit)) = items[0] else {
            return XCTFail("Expected guardrail decision state write")
        }
        XCTAssertEqual(valueTypeName, "Bool")
        guard case let .leaf(.modelInput(config, _, _)) = value else {
            return XCTFail("Expected modelInput leaf in decision write, got \(PipelineGraphTestHelpers.prettyPrint(value))")
        }
        XCTAssertEqual(config.outputTypeName, "Bool")
        XCTAssertTrue(config.traits.contains(.guardrailClassification))

        guard case let .sequence(branchItems) = items[1],
              case .group(sequential: true, gate: true, _) = branchItems.first else {
            return XCTFail("Expected state-dependent native branch")
        }
    }

    func testGuardrail_emptyRules_lowersDirectlyToAllowedBranch() {
        let graph = Guardrail(
            "Hello",
            rules: [],
            allowed: { Just(value: "allowed") },
            blocked: { Just(value: "blocked") }
        ).loweredGraph()

        guard case let .leaf(.just(valueTypeName, jsonUTF8)) = graph else {
            return XCTFail("Expected allowed branch only, got \(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        XCTAssertEqual(valueTypeName, "String")
        XCTAssertEqual(jsonUTF8, "\"allowed\"")
    }

    func testGuardrailCreatedInsideBodyKeepsStableStateIDAcrossLowerings() {
        struct Host: Pipeline {
            var body: some Pipeline {
                Guardrail(
                    "Hello",
                    rules: [.illegal],
                    allowed: { Just(value: "allowed") },
                    blocked: { Just(value: "blocked") }
                )
            }
        }

        func stateID(in graph: PipelineGraph) -> UUID? {
            guard case let .sequence(items) = graph,
                  case let .leaf(.executionStateSet(id, _, _, _, _)) = items.first else {
                return nil
            }
            return id
        }

        XCTAssertEqual(
            stateID(in: Host().loweredGraph()),
            stateID(in: Host().loweredGraph())
        )
    }

    func testStableIDSequenceUsesFixedWidth48BitSuffix() {
        let context = GraphEmissionContext(stableIDSequence: 0x0001_0000_0000_0000)

        XCTAssertEqual(
            context.nextStableID().uuidString,
            "E11C0000-0000-4000-8000-000000000000"
        )
    }

    func testStableIDSequenceDoesNotTrapAtUInt64Max() {
        let context = GraphEmissionContext(stableIDSequence: UInt64.max)

        XCTAssertEqual(
            context.nextStableID().uuidString,
            "E11C0000-0000-4000-8000-FFFFFFFFFFFF"
        )
        XCTAssertEqual(
            context.nextStableID().uuidString,
            "E11C0000-0000-4000-8000-000000000000"
        )
    }

    // MARK: - Control-flow read emission (read() injects stateGet at conditional boundary)

    func testRead_ifElse_injectsStateGetBeforeBranch() {
        struct Host: Pipeline {
            typealias Output = String
            @State var flag: String = ""

            var body: some Pipeline {
                $flag.set("value")
                if flag == "value" {
                    Model<String>().systemPrompt("yes").message(flag)
                } else {
                    Model<String>().systemPrompt("no").message(flag)
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
                    Model<String>().systemPrompt("yes").message(flag)
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
                Model<String>().systemPrompt("always").message(flag)
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

}
