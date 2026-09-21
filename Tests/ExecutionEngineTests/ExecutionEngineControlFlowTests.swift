//
//  ExecutionEngineControlFlowTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
import PipelineCompiler
import PipelineDSL
@testable import ExecutionEngine

final class ExecutionEngineControlFlowTests: XCTestCase {

    private let compiler = PipelineCompiler(optimizations: [.parallelize])
    private let engine = PipelineWalker(executor: MockExecutor())

    // MARK: - AST helpers

    private func stateGet(_ id: UUID, defaultJSON: String = "\"\"") -> PipelineGraph {
        .leaf(.executionStateGet(id: id, valueTypeName: "String", debugLabel: nil, defaultJSON: defaultJSON))
    }

    private func stateSet(_ id: UUID, value: PipelineGraph) -> PipelineGraph {
        .leaf(.executionStateSet(id: id, valueTypeName: "String", value: value, debugLabel: nil, writeKind: .commit))
    }

    private func stringConstant(_ s: String) throws -> PipelineGraph {
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        return .leaf(.just(valueTypeName: "String", jsonUTF8: json))
    }

    private func runAST(_ ast: PipelineGraph) async throws -> [ExecutionEvent] {
        let graph = compiler.compile(ast)
        var events: [ExecutionEvent] = []
        _ = try await engine.run(graph: graph, observingExecution: { events.append($0) })
        return events
    }

    private func runLowered(_ pipeline: some Pipeline) async throws -> [ExecutionEvent] {
        let graph = compiler.compile(pipeline.loweredGraph())
        var events: [ExecutionEvent] = []
        _ = try await engine.run(graph: graph, observingExecution: { events.append($0) })
        return events
    }

    private func firstIndex(
        where predicate: (ExecutionEvent) -> Bool,
        in events: [ExecutionEvent]
    ) -> Int? {
        events.firstIndex(where: predicate)
    }

    private func lastStateValue(for slotID: UUID, in events: [ExecutionEvent]) -> ExecutionValue? {
        events.reversed().lazy.compactMap { event -> ExecutionValue? in
            if case .stateUpdated(let u) = event, u.slotID == slotID { return u.value }
            return nil
        }.first
    }

    private func decodeString(_ data: ExecutionValue) throws -> String {
        try JSONDecoder().decode(String.self, from: data)
    }

    // MARK: - Gate successor: branch writes a slot the gate never reads (slot-only edges insufficient)

    func testGateSuccessor_writeToUnrelatedSlotStillAfterGate() async throws {
        let severity = UUID()
        let category = UUID()

        let ast: PipelineGraph = .sequence([
            stateSet(severity, value: try stringConstant("high")),
            .group(sequential: true, gate: true, stateGet(severity)),
            stateSet(category, value: try stringConstant("billing")),
        ])

        let events = try await runAST(ast)

        let gateReadDone = firstIndex(where: {
            if case .stepCompleted(let info, _, _) = $0 { return info.operationLabel == "stateGet" }
            return false
        }, in: events)

        let categoryWrite = firstIndex(where: {
            if case .stateUpdated(let u) = $0, u.slotID == category { return true }
            return false
        }, in: events)

        XCTAssertNotNil(gateReadDone)
        XCTAssertNotNil(categoryWrite)
        XCTAssertLessThan(
            gateReadDone!,
            categoryWrite!,
            "buildGateSuccessorEdges must order the post-gate write even when it does not touch the gated slot"
        )

        let cat = try XCTUnwrap(lastStateValue(for: category, in: events))
        XCTAssertEqual(try decodeString(cat), "billing")
    }

    // MARK: - Multiple control-flow reads in one gate

    func testGatedSequence_twoReadsBeforeBranch() async throws {
        let a = UUID()
        let b = UUID()
        let out = UUID()

        let ast: PipelineGraph = .sequence([
            stateSet(a, value: try stringConstant("1")),
            stateSet(b, value: try stringConstant("2")),
            .group(sequential: true, gate: true, .sequence([stateGet(a), stateGet(b)])),
            stateSet(out, value: try stringConstant("ok")),
        ])

        let events = try await runAST(ast)

        let secondReadDone = events.lastIndex(where: {
            if case .stepCompleted(let info, _, _) = $0 { return info.operationLabel == "stateGet" }
            return false
        })

        let outWrite = firstIndex(where: {
            if case .stateUpdated(let u) = $0, u.slotID == out { return true }
            return false
        }, in: events)

        XCTAssertNotNil(secondReadDone)
        XCTAssertNotNil(outWrite)
        XCTAssertLessThan(secondReadDone!, outWrite!, "Branch must run only after all gated reads complete")
    }

    // MARK: - DSL: `if` / `else` lowering + engine (control-flow reads → gate)

    func testDSL_ifBranch_takenWhenReadMatchesAtLowerTime() async throws {
        struct Host: Pipeline {
            typealias Output = String
            @State var mode: String = "pickme"
            @State var out: String = ""

            var body: some Pipeline {
                $mode.set("pickme")
                if mode == "pickme" {
                    $out.set("THEN")
                } else {
                    $out.set("ELSE")
                }
            }
        }

        let host = Host()
        let events = try await runLowered(host)
        let value = try XCTUnwrap(lastStateValue(for: host.$out.id, in: events))
        XCTAssertEqual(try decodeString(value), "THEN")
    }

    func testDSL_elseBranch_takenWhenReadDoesNotMatchInitialSlot() async throws {
        struct Host: Pipeline {
            typealias Output = String
            @State var mode: String = "mismatch"
            @State var out: String = ""

            var body: some Pipeline {
                $mode.set("pickme")
                if mode == "pickme" {
                    $out.set("THEN")
                } else {
                    $out.set("ELSE")
                }
            }
        }

        let host = Host()
        let events = try await runLowered(host)
        let value = try XCTUnwrap(lastStateValue(for: host.$out.id, in: events))
        XCTAssertEqual(try decodeString(value), "ELSE")
    }

    func testDSL_ifWithModel_gateRunsBeforeModelUsesSlot() async throws {
        struct Host: Pipeline {
            typealias Output = String
            /// `read()` during lowering uses ``State/initialValue``, not a later `$flag.set` in the same body.
            @State var flag: String = "go"
            @State var topic: String = "hi"

            var body: some Pipeline {
                if flag == "go" {
                    Model<String>().systemPrompt("yes").message(topic)
                } else {
                    Model<String>().systemPrompt("no").message(topic)
                }
            }
        }

        let host = Host()
        let events = try await runLowered(host)

        let gateGetDone = firstIndex(where: {
            if case .stepCompleted(let info, _, _) = $0, info.operationLabel == "stateGet" { return true }
            return false
        }, in: events)

        let modelDone = firstIndex(where: {
            if case .stepCompleted(let info, _, _) = $0, info.operationLabel == "model" { return true }
            return false
        }, in: events)

        XCTAssertNotNil(gateGetDone)
        XCTAssertNotNil(modelDone)
        XCTAssertLessThan(
            gateGetDone!,
            modelDone!,
            "Injected control-flow read must finish before the taken branch model runs"
        )
    }

    func testDSL_setThenConditional_orderingSurvivesParallelize() async throws {
        struct Host: Pipeline {
            typealias Output = String
            /// Initial matches the `if` predicate so the **then** branch is lowered (read uses initial at graph build).
            @State var severity: String = "high"
            @State var category: String = ""

            var body: some Pipeline {
                $severity.set("high")
                if severity == "high" {
                    $category.set("billing")
                } else {
                    $category.set("other")
                }
            }
        }

        let host = Host()
        let events = try await runLowered(host)

        let sevWrite = firstIndex(where: {
            if case .stateUpdated(let u) = $0, u.slotID == host.$severity.id { return true }
            return false
        }, in: events)

        let catWrite = firstIndex(where: {
            if case .stateUpdated(let u) = $0, u.slotID == host.$category.id { return true }
            return false
        }, in: events)

        XCTAssertNotNil(sevWrite)
        XCTAssertNotNil(catWrite)
        XCTAssertLessThan(sevWrite!, catWrite!, "Category write must follow severity write and gated condition")

        let cat = try XCTUnwrap(lastStateValue(for: host.$category.id, in: events))
        XCTAssertEqual(try decodeString(cat), "billing")
    }
}
