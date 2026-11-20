//
//  ModelRequirementsFlowTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
@testable import PipelineDSL

/// Step B — `Model.requirements(_:)` must carry `backend` and `spec` into the lowered `ModelConfig`
/// (not just `traits`), so a step can select a specific model — e.g. the delegate's shared base model.
final class ModelRequirementsFlowTests: XCTestCase {

    private struct P: Pipeline {
        typealias Output = String
        let req: ModelSelectionRequirements
        @State var out = ""
        var body: some Pipeline {
            $out.set { Model<String>().requirements(req).message("hi") }
            $out.get()
        }
    }

    func testBackendAndSpecReachModelConfig() throws {
        let req = ModelSelectionRequirements(
            backend: .mlx,
            traits: .chatCompletion,
            spec: ModelSpecDescriptor(sourceID: "acme/model", revision: "r1")
        )
        let graph = P(req: req).loweredGraph()

        guard let config = firstModelConfig(in: graph) else {
            return XCTFail("expected a .model leaf in the lowered graph")
        }
        XCTAssertEqual(config.backend, .mlx)
        XCTAssertEqual(config.spec?.sourceID, "acme/model")
        XCTAssertEqual(config.spec?.revision, "r1")
        XCTAssertTrue(config.traits.contains(.chatCompletion))
    }

    private func firstModelConfig(in graph: PipelineGraph) -> ModelConfig? {
        switch graph {
        case let .leaf(leaf):
            switch leaf {
            case let .model(config, _), let .modelInput(config, _, _):
                return config
            case let .executionStateSet(_, _, value, _, _):
                return firstModelConfig(in: value)
            default:
                return nil
            }
        case let .sequence(items):
            return items.lazy.compactMap { self.firstModelConfig(in: $0) }.first
        case let .returnWith(inner), let .group(_, _, inner), let .loop(inner):
            return firstModelConfig(in: inner)
        case let .branch(_, then, otherwise):
            return firstModelConfig(in: then) ?? firstModelConfig(in: otherwise)
        case let .whileLoop(_, body):
            return firstModelConfig(in: body)
        case .empty:
            return nil
        }
    }
}
