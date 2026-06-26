//
//  ExecutionEngineParallelizationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
import PipelineCompiler
@testable import ExecutionEngine

final class ExecutionEngineParallelizationTests: XCTestCase {

    private let compiler = PipelineCompiler(optimizations: [.parallelize])
    private let engine = PipelineWalker(executor: MockExecutor())

    private let slotA = UUID()
    private let slotB = UUID()
    private let slotC = UUID()

    // MARK: - AST helpers (mirror ``PipelineCompilerTests`` shapes)

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

    private func opaque(_ name: String) -> PipelineGraph {
        .leaf(.opaque(typeName: name))
    }

    private func modelReadInput(instructions: String, input: PipelineGraph) -> PipelineGraph {
        let instrJSON = String(decoding: (try? JSONEncoder().encode(instructions)) ?? Data(), as: UTF8.self)
        return .leaf(.model(
            instructions: .leaf(.just(valueTypeName: "String", jsonUTF8: instrJSON)),
            tools: .empty,
            input: input,
            outputTypeName: "String",
            requirements: nil
        ))
    }

    // MARK: - Run harness

    private func runCompiled(_ ast: PipelineGraph) async throws -> [ExecutionEvent] {
        let graph = compiler.compile(ast)
        var events: [ExecutionEvent] = []
        _ = try await engine.run(graph: graph, observingExecution: { events.append($0) })
        return events
    }

    private func firstIndex(where matches: (ExecutionEvent) -> Bool, in events: [ExecutionEvent]) -> Int? {
        events.firstIndex(where: matches)
    }

    private func lastIndex(where matches: (ExecutionEvent) -> Bool, in events: [ExecutionEvent]) -> Int? {
        events.lastIndex(where: matches)
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

    // MARK: - Fan-in: parallel writes must finish before merge that reads both

    func testFanIn_mergeStateUpdateAfterParallelGroup() async throws {
        let readBoth: PipelineGraph = .sequence([stateGet(slotA), stateGet(slotB)])
        let merge = stateSet(slotC, value: readBoth)

        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: try stringConstant("alpha")),
            stateSet(slotB, value: try stringConstant("beta")),
            merge,
        ])

        let events = try await runCompiled(ast)

        let parallelDone = firstIndex(where: {
            if case .parallelGroupCompleted(let count, let executed) = $0 {
                return count == 2 && executed == 2
            }
            return false
        }, in: events)

        let cWrite = firstIndex(where: {
            if case .stateUpdated(let u) = $0, u.slotID == slotC { return true }
            return false
        }, in: events)

        XCTAssertNotNil(parallelDone, "Expected a completed 2-branch parallel group")
        XCTAssertNotNil(cWrite, "Expected a write to slot C")
        XCTAssertLessThan(parallelDone!, cWrite!, "Merge must observe both writes after the parallel batch completes")

        let cValue = try XCTUnwrap(lastStateValue(for: slotC, in: events))
        XCTAssertEqual(try decodeString(cValue), "beta", "Sequential value walk uses the last subgraph result (slot B)")
    }

    // MARK: - Gate: guardrail must complete before parallel writes start

    func testGate_parallelGroupStartsAfterGuardrailCompletes() async throws {
        let ast: PipelineGraph = .sequence([
            .group(sequential: true, gate: true, .leaf(.guardrail(rules: [.pii]))),
            stateSet(slotA, value: try stringConstant("x")),
            stateSet(slotB, value: try stringConstant("y")),
        ])

        let events = try await runCompiled(ast)

        let guardrailDone = lastIndex(where: {
            if case .stepCompleted(let info, _, _) = $0 { return info.operationLabel == "guardrail" }
            return false
        }, in: events)

        let parallelStart = firstIndex(where: {
            if case .parallelGroupStarted(let count) = $0 { return count == 2 }
            return false
        }, in: events)

        XCTAssertNotNil(guardrailDone)
        XCTAssertNotNil(parallelStart)
        XCTAssertLessThan(guardrailDone!, parallelStart!, "Gate successor must not run in parallel with the gate")
    }

    // MARK: - WAR: read slot then overwrite — strict sequential completion

    func testWriteAfterRead_threeSequentialSteps() async throws {
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: try stringConstant("init")),
            modelReadInput(instructions: "read", input: stateGet(slotA)),
            stateSet(slotA, value: try stringConstant("overwrite")),
        ])

        let events = try await runCompiled(ast)
        let completedLabels = events.compactMap { event -> String? in
            if case .stepCompleted(let info, _, _) = event { return info.operationLabel }
            return nil
        }

        XCTAssertEqual(
            completedLabels,
            ["stateSet", "model", "stateSet"],
            "RAW/WAR edges must keep init → read-model → overwrite strictly sequential"
        )
    }

    // MARK: - WAW: repeated writes to one slot stay sequential

    func testWriteAfterWrite_sameSlotSequential() async throws {
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: try stringConstant("first")),
            stateSet(slotA, value: try stringConstant("second")),
            stateSet(slotA, value: try stringConstant("third")),
        ])

        let events = try await runCompiled(ast)
        XCTAssertNil(
            firstIndex(where: { if case .parallelGroupStarted = $0 { return true }; return false }, in: events),
            "Same-slot WAW chain must not introduce a parallel group"
        )

        let lastA = try XCTUnwrap(lastStateValue(for: slotA, in: events))
        XCTAssertEqual(try decodeString(lastA), "third")
    }

    // MARK: - Concurrent readers after one write (same slot) — one parallel batch

    func testConcurrentReadsAfterWrite_twoModelsInParallel() async throws {
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: try stringConstant("shared")),
            modelReadInput(instructions: "reader-1", input: stateGet(slotA)),
            modelReadInput(instructions: "reader-2", input: stateGet(slotA)),
        ])

        let events = try await runCompiled(ast)

        let parallelBatch = events.compactMap { event -> (count: Int, executed: Int)? in
            if case .parallelGroupCompleted(let count, let executed) = event {
                return (count, executed)
            }
            return nil
        }

        XCTAssertEqual(parallelBatch.count, 1, "Expected exactly one parallel group for the two readers")
        XCTAssertEqual(parallelBatch[0].count, 2)
        XCTAssertEqual(parallelBatch[0].executed, 2, "Both reader branches should execute (not memo-skipped on first pass)")

        let modelCompletions = events.filter {
            if case .stepCompleted(let info, _, _) = $0 { return info.operationLabel == "model" }
            return false
        }
        XCTAssertEqual(modelCompletions.count, 2)
    }

    // MARK: - Write then read model — no premature parallelization with merge

    func testWriteThenRead_modelRunsAfterSetNotInParallelWithIt() async throws {
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: try stringConstant("ctx")),
            modelReadInput(instructions: "use", input: stateGet(slotA)),
        ])

        let events = try await runCompiled(ast)
        XCTAssertNil(
            firstIndex(where: { if case .parallelGroupStarted = $0 { return true }; return false }, in: events),
            "RAW dependency must keep set and model sequential (no parallel group)"
        )

        let labels = events.compactMap { event -> String? in
            if case .stepCompleted(let info, _, _) = event { return info.operationLabel }
            return nil
        }
        XCTAssertEqual(labels, ["stateSet", "model"])
    }

    // MARK: - Conservative ordering: opaque nodes without slot access stay ordered

    func testConservativeOrdering_twoOpaquesNoParallelGroup() async throws {
        let ast: PipelineGraph = .sequence([
            opaque("A"),
            opaque("B"),
        ])

        let events = try await runCompiled(ast)
        XCTAssertNil(
            firstIndex(where: { if case .parallelGroupStarted = $0 { return true }; return false }, in: events),
            "Opaque nodes without slot edges must stay sequential (conservative ordering)"
        )

        let constants = events.filter {
            if case .stepCompleted(let info, _, _) = $0 { return info.operationLabel == "constant" }
            return false
        }
        XCTAssertEqual(constants.count, 2, "Opaque leaves lower to constant tasks")
    }

    // MARK: - Without `.parallelize`, independent writes must not form a runtime parallel group

    func testWithoutParallelizeOptimization_noParallelGroupEmitted() async throws {
        let sequentialCompiler = PipelineCompiler(optimizations: .none)
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: try stringConstant("a")),
            stateSet(slotB, value: try stringConstant("b")),
        ])
        let graph = sequentialCompiler.compile(ast)
        var events: [ExecutionEvent] = []
        _ = try await engine.run(graph: graph, observingExecution: { events.append($0) })

        XCTAssertNil(
            firstIndex(where: { if case .parallelGroupStarted = $0 { return true }; return false }, in: events),
            "With optimizations disabled the emitter keeps a flat sequential graph; the engine must not invent parallel batches"
        )
    }

    // MARK: - Independent writes then model merge (compiler shape + engine semantics)

    func testIndependentWritesThenMerge_parallelThenSequentialModel() async throws {
        let mergeInput: PipelineGraph = .sequence([stateGet(slotA), stateGet(slotB), stateGet(slotC)])
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: opaque("SearchWeb")),
            stateSet(slotB, value: opaque("SearchDocs")),
            stateSet(slotC, value: opaque("SearchCache")),
            modelReadInput(instructions: "Merge", input: mergeInput),
        ])

        let events = try await runCompiled(ast)

        let parallelDone = firstIndex(where: {
            if case .parallelGroupCompleted(let count, _) = $0 { return count == 3 }
            return false
        }, in: events)
        let modelDone = firstIndex(where: {
            if case .stepCompleted(let info, _, _) = $0 { return info.operationLabel == "model" }
            return false
        }, in: events)

        XCTAssertNotNil(parallelDone)
        XCTAssertNotNil(modelDone)
        XCTAssertLessThan(parallelDone!, modelDone!, "Merge model must run after the three-way parallel search batch")
    }
}
