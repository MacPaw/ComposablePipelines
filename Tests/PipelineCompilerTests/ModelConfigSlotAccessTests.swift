//
//  ModelConfigSlotAccessTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
@testable import PipelineCompiler

/// Dependency edges for `ModelConfig`'s slot-backed fields.
///
/// Each one is read by the walker immediately before the call, so each needs a read edge — otherwise the
/// topological sort may place the model *ahead* of the step that fills the slot. For the tool allowlist
/// that is not merely a stale value: narrowing fails closed, so a lost ordering edge silently produces a
/// tool-less model turn.
final class ModelConfigSlotAccessTests: XCTestCase {

    private let contextSlot = UUID()
    private let priorTurnsSlot = UUID()
    private let allowlistSlot = UUID()

    private var config: ModelConfig {
        ModelConfig(
            outputTypeName: "String",
            contextItemsSlotIDs: [contextSlot],
            priorTurnsSlotID: priorTurnsSlot,
            toolAllowlistSlotID: allowlistSlot
        )
    }

    func testModelLeafReadsEverySlotBackedField() {
        let access = SlotAccess.collect(from: .leaf(.model(config: config, arguments: [:])))
        XCTAssertEqual(access.reads, [contextSlot, priorTurnsSlot, allowlistSlot])
    }

    func testModelInputLeafReadsTheSameFields() {
        // `.modelInput` used to omit `priorTurnsSlotID` here and in the walker; both now share one
        // helper, so the two leaves cannot drift again.
        let access = SlotAccess.collect(from: .leaf(.modelInput(
            config: config,
            arguments: [:],
            input: .leaf(.just(valueTypeName: "String", jsonUTF8: #""hi""#))
        )))
        XCTAssertEqual(access.reads, [contextSlot, priorTurnsSlot, allowlistSlot])
    }
}
