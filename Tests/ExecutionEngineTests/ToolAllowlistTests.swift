//
//  ToolAllowlistTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineCompiler
@testable import ExecutionEngine

/// `ModelConfig.toolAllowlistSlotID` — the runtime narrowing of a model step's advertised tools.
///
/// Every assertion is about what the *executor was handed*, because that is what the model sees. The
/// invariant under test is one-way: an allowlist may only ever remove tools from the catalog the graph
/// declares, so filling the slot from model output can never widen a step's reach.
final class ToolAllowlistTests: XCTestCase {

    private let allowlistSlot = UUID()

    private func tool(_ name: String) -> ToolDescriptor {
        ToolDescriptor(name: name, description: "does \(name)", inputSchema: .object(properties: [:]))
    }

    private var catalog: [ToolDescriptor] { [tool("alpha"), tool("beta"), tool("gamma")] }

    /// A single model step declaring `catalog`, optionally narrowed by a slot the graph writes first.
    private func graph(allowlistJSON: String?, declaresSlot: Bool = true) -> PipelineGraph {
        let config = ModelConfig(
            outputTypeName: "String",
            toolAllowlistSlotID: declaresSlot ? allowlistSlot : nil
        )
        let arguments: ModelArguments = [ModelArgumentKey.tools.rawValue: .tools(catalog)]
        let model = PipelineGraph.leaf(.model(config: config, arguments: arguments))
        guard let allowlistJSON else { return model }
        return .sequence([
            .leaf(.executionStateSet(
                id: allowlistSlot,
                valueTypeName: "Array<String>",
                value: .leaf(.just(valueTypeName: "Array<String>", jsonUTF8: allowlistJSON)),
                debugLabel: "granted",
                writeKind: .commit
            )),
            model,
        ])
    }

    /// Runs the graph and returns the tool names the executor was actually advertised.
    private func advertisedTools(_ graph: PipelineGraph) async throws -> [String] {
        let box = Box()
        let executor = ScriptedExecutor { call in
            box.set(call.tools.map(\.name))
            return ScriptedExecutor.string("ok")
        }
        _ = try await PipelineWalker(executor: executor).run(graph: PipelineCompiler().compile(graph))
        return box.value
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var value: [String] { lock.withLock { storage } }
        func set(_ value: [String]) { lock.withLock { storage = value } }
    }

    // MARK: - Narrowing

    func testNoAllowlistSlotAdvertisesTheFullCatalog() async throws {
        let names = try await advertisedTools(graph(allowlistJSON: nil, declaresSlot: false))
        XCTAssertEqual(names, ["alpha", "beta", "gamma"],
                       "a step that declares no allowlist keeps every tool it was built with")
    }

    func testAllowlistNarrowsToTheNamedSubset() async throws {
        let names = try await advertisedTools(graph(allowlistJSON: #"["alpha"]"#))
        XCTAssertEqual(names, ["alpha"])
    }

    func testEmptyAllowlistAdvertisesNoTools() async throws {
        let names = try await advertisedTools(graph(allowlistJSON: "[]"))
        XCTAssertEqual(names, [], "an explicit empty grant means the model answers without tools")
    }

    func testUnknownNamesAreIgnoredRatherThanAdded() async throws {
        let names = try await advertisedTools(graph(allowlistJSON: #"["beta","nope","alpha"]"#))
        XCTAssertEqual(names, ["alpha", "beta"],
                       "narrowing filters the declared catalog, so an invented name cannot appear")
    }

    func testNarrowingPreservesDeclarationOrder() async throws {
        // The allowlist is deliberately reversed: order comes from the catalog, not the request, so a
        // model cannot reorder the tools it is shown (prompt order biases small models' choices).
        let names = try await advertisedTools(graph(allowlistJSON: #"["gamma","beta","alpha"]"#))
        XCTAssertEqual(names, ["alpha", "beta", "gamma"])
    }

    // MARK: - Fail-closed

    func testDeclaredButUnwrittenSlotGrantsNothing() async throws {
        // Declaring the slot IS the narrowing statement. If the write is missing or was skipped, the
        // step must NOT silently fall back to its full catalog — that would turn a dropped step into an
        // invisible capability grant.
        let names = try await advertisedTools(graph(allowlistJSON: nil, declaresSlot: true))
        XCTAssertEqual(names, [], "an unwritten allowlist grants nothing, not everything")
    }

    func testMalformedAllowlistThrowsRatherThanWidening() async throws {
        let bad = PipelineGraph.sequence([
            .leaf(.executionStateSet(
                id: allowlistSlot,
                valueTypeName: "String",
                value: .leaf(.just(valueTypeName: "String", jsonUTF8: #""not-a-list""#)),
                debugLabel: "granted",
                writeKind: .commit
            )),
            .leaf(.model(
                config: ModelConfig(outputTypeName: "String", toolAllowlistSlotID: allowlistSlot),
                arguments: [ModelArgumentKey.tools.rawValue: .tools(catalog)]
            )),
        ])
        let executor = ScriptedExecutor { _ in ScriptedExecutor.string("ok") }
        do {
            _ = try await PipelineWalker(executor: executor).run(graph: PipelineCompiler().compile(bad))
            XCTFail("a malformed allowlist must surface, not degrade to the full catalog")
        } catch ExecutionError.toolAllowlistDecodingFailed(let slotID, _) {
            XCTAssertEqual(slotID, allowlistSlot)
        }
    }
}
