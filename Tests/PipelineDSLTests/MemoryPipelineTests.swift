//
//  MemoryPipelineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL

final class MemoryPipelineTests: XCTestCase {
    func testExtractComposesEntityExtractionAndNormalizationModels() {
        let graph = Memory.extract(from: "release preferences").pipelineGraph

        guard case let .leaf(.modelInput(normalization, arguments, input)) = graph else {
            XCTFail("expected typed normalization model")
            return
        }

        XCTAssertEqual(normalization.outputTypeName, "MemoryItems")
        XCTAssertTrue(normalization.traits.contains(.memoryNormalization))
        XCTAssertNil(arguments.message)

        guard case let .leaf(.model(extraction, extractionArguments)) = input else {
            XCTFail("expected entity extraction input")
            return
        }
        XCTAssertEqual(extraction.outputTypeName, "MemoryEntities")
        XCTAssertTrue(extraction.traits.contains(.entityExtraction))
        XCTAssertEqual(extractionArguments.message, .string("release preferences"))
    }

    func testRecallLowersToMemoryQueryLeaf() {
        let graph = Memory.recall("user goals", quality: .quick).pipelineGraph

        guard case let .leaf(.memoryQuery(quality, query)) = graph else {
            XCTFail("expected memoryQuery leaf")
            return
        }
        XCTAssertEqual(quality, .quick)

        guard case let .leaf(.just(valueTypeName, jsonUTF8)) = query else {
            XCTFail("expected constant query")
            return
        }
        XCTAssertEqual(valueTypeName, "String")
        XCTAssertEqual(jsonUTF8, "\"user goals\"")
    }

    func testContextModifierFeedsRecallIntoModel() {
        let graph = Model<String>
            .chat(systemPrompt: "Use relevant memory")
            .message("What are my goals?")
            .context {
                Memory.recall("user goals")
            }
            .pipelineGraph

        guard case let .sequence(items) = graph, items.count == 2 else {
            XCTFail("expected context write followed by model call")
            return
        }
        let contextWrite = items[0]
        let modelCall = items[1]
        guard case let .leaf(
            .executionStateSet(contextSlotID, _, contextGraph, "modelContext", .draft)
        ) = contextWrite else {
            XCTFail("expected model context state write")
            return
        }
        guard case .leaf(.memoryQuery) = contextGraph else {
            XCTFail("expected memory recall as context source")
            return
        }
        guard case let .leaf(.model(config, _)) = modelCall else {
            XCTFail("expected model call")
            return
        }
        XCTAssertEqual(config.contextItemsSlotIDs, [contextSlotID])
    }

    func testStoreEntryLowersToMemoryStoreLeaf() throws {
        let entry = MemoryEntry(id: "goal", text: "Ship the release")
        let graph = Memory.store(entry).pipelineGraph

        guard case let .leaf(.memoryStore(planGraph, mode)) = graph else {
            XCTFail("expected memoryStore leaf")
            return
        }
        XCTAssertEqual(mode ?? .sync, .sync)
        guard case let .leaf(.just(_, jsonUTF8)) = planGraph else {
            XCTFail("expected constant memory write plan")
            return
        }

        let plan = try JSONDecoder().decode(MemoryWritePlan.self, from: Data(jsonUTF8.utf8))
        XCTAssertEqual(plan.entries, [entry])
    }

    func testStoreAcceptsPipelineProducedPlan() {
        let graph = Memory.store {
            Model<MemoryWritePlan>
                .classify(systemPrompt: "Return durable memories, or an empty entries array.")
                .message("I prefer concise answers.")
        }
        .pipelineGraph

        guard case let .leaf(.memoryStore(planGraph, mode)) = graph,
              case let .leaf(.model(config, _)) = planGraph else {
            XCTFail("expected model-produced memory write plan")
            return
        }
        XCTAssertEqual(mode ?? .sync, .sync)
        XCTAssertEqual(config.outputTypeName, "MemoryWritePlan")
        XCTAssertTrue(config.traits.contains(.textClassification))
    }

    func testStoreEntryCanLowerToAsyncMemoryStoreLeaf() {
        let entry = MemoryEntry(id: "goal", text: "Ship the release")
        let graph = Memory.store(entry, mode: .async).pipelineGraph

        guard case let .leaf(.memoryStore(_, mode)) = graph else {
            XCTFail("expected memoryStore leaf")
            return
        }
        XCTAssertEqual(mode, .async as MemoryStoreMode?)
    }
}
