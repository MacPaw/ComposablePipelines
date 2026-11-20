//
//  ToolAllowlistDSLTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL

/// `Model.toolAllowlist(_:)` and the additive `ModelConfig` field behind it.
final class ToolAllowlistDSLTests: XCTestCase {

    private struct Harness: Pipeline {
        typealias Output = String
        @State var granted: [String] = []
        @State var other: [String] = []
        let useOther: Bool

        var body: some Pipeline {
            Model<String>()
                .tools([ToolDescriptor(name: "a", description: "a", inputSchema: .object(properties: [:]))])
                .toolAllowlist(useOther ? $other : $granted)
                .message("hi")
        }
    }

    private func config(of pipeline: some Pipeline) throws -> ModelConfig {
        func find(_ graph: PipelineGraph) -> ModelConfig? {
            switch graph {
            case let .leaf(.model(config, _)): return config
            case let .leaf(.modelInput(config, _, _)): return config
            case let .sequence(items): return items.lazy.compactMap(find).first
            case let .group(_, _, body): return find(body)
            default: return nil
            }
        }
        guard let config = find(pipeline.pipelineGraph) else {
            throw XCTSkip("no model leaf in graph")
        }
        return config
    }

    // MARK: - DSL

    func testToolAllowlistRecordsTheBindingSlot() throws {
        let pipeline = Harness(useOther: false)
        XCTAssertEqual(try config(of: pipeline).toolAllowlistSlotID, pipeline.$granted.id)
    }

    func testStepsWithoutAnAllowlistDeclareNoSlot() throws {
        struct Plain: Pipeline {
            typealias Output = String
            var body: some Pipeline { Model<String>().message("hi") }
        }
        XCTAssertNil(try config(of: Plain()).toolAllowlistSlotID)
    }

    func testLastAllowlistWins() throws {
        // Allowlists compose by intersection, which chaining cannot express — so the modifier replaces
        // rather than accumulates, and that has to stay deliberate.
        let pipeline = Harness(useOther: true)
        XCTAssertEqual(try config(of: pipeline).toolAllowlistSlotID, pipeline.$other.id)
    }

    func testOtherSlotBackedFieldsSurviveTheAllowlistModifier() throws {
        struct Chained: Pipeline {
            typealias Output = String
            @State var items: [ContextItem] = []
            @State var turns: [ConversationTurn] = []
            @State var granted: [String] = []

            var body: some Pipeline {
                Model<String>()
                    .contextItems($items)
                    .priorTurns($turns)
                    .toolAllowlist($granted)
                    .message("hi")
            }
        }
        let pipeline = Chained()
        let config = try config(of: pipeline)
        XCTAssertEqual(config.contextItemsSlotIDs, [pipeline.$items.id])
        XCTAssertEqual(config.priorTurnsSlotID, pipeline.$turns.id)
        XCTAssertEqual(config.toolAllowlistSlotID, pipeline.$granted.id)
    }

    // MARK: - Wire compatibility

    func testConfigRoundTripsThroughJSON() throws {
        let original = ModelConfig(
            outputTypeName: "ModelTurn",
            traits: .chatCompletion,
            contextItemsSlotIDs: [UUID()],
            priorTurnsSlotID: UUID(),
            toolAllowlistSlotID: UUID()
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ModelConfig.self, from: data), original)
    }

    func testAbsentFieldIsOmittedFromTheEncodedPayload() throws {
        let data = try JSONEncoder().encode(ModelConfig(outputTypeName: "String"))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["toolAllowlistSlotID"],
                     "the field is additive: a step that does not narrow adds nothing to the wire")
    }

    func testLegacyPayloadWithoutTheFieldStillDecodes() throws {
        // An older client's graph must keep working on a newer agent — it simply does not narrow.
        let legacy = Data(#"{"outputTypeName":"String","traits":128,"contextItemsSlotIDs":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ModelConfig.self, from: legacy)
        XCTAssertNil(decoded.toolAllowlistSlotID)
        XCTAssertEqual(decoded.traits, .chatCompletion)
    }
}
