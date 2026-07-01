//
//  PipelineCompilerTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
@testable import PipelineCompiler

final class PipelineCompilerTests: XCTestCase {

    let compiler = PipelineCompiler()

    // MARK: - Helpers

    private let slotA = UUID()
    private let slotB = UUID()
    private let slotC = UUID()
    private let messageSlot = UUID()
    private let contextSlot = UUID()

    private func stateGet(_ id: UUID, label: String? = nil, defaultJSON: String = "\"\"") -> PipelineGraph {
        .leaf(.executionStateGet(id: id, valueTypeName: "String", debugLabel: label, defaultJSON: defaultJSON))
    }

    private func stateSet(_ id: UUID, value: PipelineGraph, label: String? = nil) -> PipelineGraph {
        .leaf(.executionStateSet(id: id, valueTypeName: "String", value: value, debugLabel: label, writeKind: .commit))
    }

    private func opaqueLeaf(_ name: String) -> PipelineGraph {
        .leaf(.opaque(typeName: name))
    }

    private func model(instructions: String, readingSlot: UUID? = nil) -> PipelineGraph {
        let config = ModelConfig(
            outputTypeName: "String",
            traits: [],
            streamingReplySlotID: nil,
            contextItemsSlotID: readingSlot
        )
        return .leaf(.model(config: config, arguments: ["systemPrompt": .systemPrompt(instructions)]))
    }

    // MARK: - Basic: linear sequence stays sequential

    func testLinearSequence_remainsSequential() {
        let ast: PipelineGraph = .sequence([
            opaqueLeaf("A"),
            opaqueLeaf("B"),
            opaqueLeaf("C"),
        ])

        let result = compiler.compile(ast)
        guard case let .sequential(steps) = result else {
            return XCTFail("Expected .sequential, got \(result)")
        }
        XCTAssertEqual(steps.count, 3)
        for step in steps {
            guard case .task = step else {
                return XCTFail("Expected .task, got \(step)")
            }
        }
    }

    func testModelTask_preservesTraits() {
        let traits: ModelSelectionTraits = [.quick, .lowMemory]
        let config = ModelConfig(
            outputTypeName: "String",
            traits: traits,
            streamingReplySlotID: nil,
            contextItemsSlotID: nil
        )
        let ast: PipelineGraph = .leaf(.model(config: config, arguments: [:]))

        let result = compiler.compile(ast)

        guard case let .task(task) = result,
              case let .model(compiledConfig, _) = task.operation else {
            return XCTFail("Expected compiled model task, got \(result)")
        }
        XCTAssertEqual(compiledConfig.traits, traits)
    }

    func testModelInput_dependsOnStateReadByNestedInput() {
        let config = ModelConfig(
            outputTypeName: "String",
            traits: .memoryNormalization
        )
        let ast: PipelineGraph = .sequence([
            stateSet(
                slotA,
                value: .leaf(.just(valueTypeName: "String", jsonUTF8: "\"car\""))
            ),
            .leaf(
                .modelInput(
                    config: config,
                    arguments: [:],
                    input: stateGet(slotA)
                )
            ),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(steps) = result, steps.count == 2 else {
            return XCTFail("Expected state write before model input, got \(result)")
        }
        guard case let .task(writeTask) = steps[0],
              case .stateSet = writeTask.operation,
              case let .task(modelTask) = steps[1],
              case let .modelInput(_, _, input) = modelTask.operation,
              case let .task(inputTask) = input,
              case .stateGet = inputTask.operation else {
            return XCTFail("Expected nested state read in model input, got \(result)")
        }
    }

    func testPrettyPrint_modelIncludesTraitsAndTools() {
        let config = ModelConfig(
            outputTypeName: "String",
            traits: [.quick],
            streamingReplySlotID: nil,
            contextItemsSlotID: nil
        )
        let graph = PipelineExecutionGraph.task(.init(operation: .model(
            config: config,
            arguments: ["tools": .tools([])]
        )))

        let printed = graph.description

        XCTAssertTrue(printed.contains("traits: [.quick]"), printed)
        XCTAssertTrue(printed.contains("tools"), printed)
    }

    // MARK: - Independent writes to different slots -> parallel

    func testIndependentSlotWrites_becomeParallel() {
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: opaqueLeaf("SearchWeb")),
            stateSet(slotB, value: opaqueLeaf("SearchDocs")),
            stateSet(slotC, value: opaqueLeaf("SearchCache")),
            model(instructions: "Merge", readingSlot: slotA),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(levels) = result else {
            return XCTFail("Expected .sequential of levels, got \(result)")
        }
        XCTAssertEqual(levels.count, 2, "Should have 2 levels: parallel writes, then model")

        guard case let .parallel(tasks) = levels[0] else {
            return XCTFail("Expected .parallel at level 0, got \(levels[0])")
        }
        XCTAssertEqual(tasks.count, 3, "Should have 3 parallel tasks")
    }

    // MARK: - Write then read -> sequential (data dependency)

    func testWriteThenRead_staysSequential() {
        let ast: PipelineGraph = .sequence([
            stateSet(contextSlot, value: opaqueLeaf("Summarize")),
            model(instructions: "Use context", readingSlot: contextSlot),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(steps) = result else {
            return XCTFail("Expected .sequential (data dependency), got \(result)")
        }
        XCTAssertEqual(steps.count, 2)
    }

    // MARK: - Mixed: two independent writes then one dependent read

    func testFanOutFanIn_parallelThenSequential() {
        let readBoth: PipelineGraph = .sequence([
            stateGet(slotA),
            stateGet(slotB),
        ])
        let merge = stateSet(slotC, value: readBoth)

        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: opaqueLeaf("SearchWeb")),
            stateSet(slotB, value: opaqueLeaf("SearchDocs")),
            merge,
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(levels) = result else {
            return XCTFail("Expected .sequential of levels, got \(result)")
        }
        XCTAssertEqual(levels.count, 2, "Should have 2 levels: parallel writes, then merge")

        guard case let .parallel(parallelTasks) = levels[0] else {
            return XCTFail("Expected .parallel at level 0, got \(levels[0])")
        }
        XCTAssertEqual(parallelTasks.count, 2, "Two independent writes should be parallel")
    }

    // MARK: - Optimization flags

    func testNoOptimizations_noParallel() {
        let noOpt = PipelineCompiler(optimizations: .none)

        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: opaqueLeaf("SearchWeb")),
            stateSet(slotB, value: opaqueLeaf("SearchDocs")),
            model(instructions: "Merge"),
        ])

        let result = noOpt.compile(ast)

        func hasParallel(_ g: PipelineExecutionGraph) -> Bool {
            switch g {
            case .parallel: return true
            case let .sequential(items): return items.contains { hasParallel($0) }
            default: return false
            }
        }
        XCTAssertFalse(hasParallel(result), "Without parallelize, no .parallel blocks expected")
    }

    // MARK: - Empty AST

    func testEmpty_producesEmpty() {
        let result = compiler.compile(.empty)
        XCTAssertEqual(result, .empty)
    }

    // MARK: - ReturnWith preservation

    func testReturnWith_isPreserved() {
        let ast: PipelineGraph = .returnWith(
            .leaf(.just(valueTypeName: "String", jsonUTF8: "\"done\""))
        )

        let result = compiler.compile(ast)

        guard case .returnWith = result else {
            return XCTFail("Expected .returnWith at top level, got \(result)")
        }
    }

    // MARK: - Read-read independence (no ordering edge between concurrent readers)

    func testConcurrentReads_becomeParallel() {
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: opaqueLeaf("Init")),
            model(instructions: "Read A first", readingSlot: slotA),
            model(instructions: "Read A second", readingSlot: slotA),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(levels) = result else {
            return XCTFail("Expected .sequential, got \(result)")
        }
        XCTAssertEqual(levels.count, 2, "Level 0: write slotA, Level 1: two parallel reads")

        guard case let .parallel(readers) = levels[1] else {
            return XCTFail("Expected .parallel for two readers at level 1, got \(levels[1])")
        }
        XCTAssertEqual(readers.count, 2, "Two read-only models should be parallel")
    }

    // MARK: - WAW ordering (write-after-write on same slot stays sequential)

    func testWriteAfterWrite_staysSequential() {
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: opaqueLeaf("First")),
            stateSet(slotA, value: opaqueLeaf("Second")),
            stateSet(slotA, value: opaqueLeaf("Third")),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(steps) = result else {
            return XCTFail("Expected .sequential (WAW chain), got \(result)")
        }
        XCTAssertEqual(steps.count, 3, "Three writes to same slot must be sequential")
    }

    // MARK: - WAR ordering (write-after-read on same slot)

    func testWriteAfterRead_staysSequential() {
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: opaqueLeaf("Init")),
            model(instructions: "Read A", readingSlot: slotA),
            stateSet(slotA, value: opaqueLeaf("Overwrite")),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(steps) = result else {
            return XCTFail("Expected .sequential (RAW + WAR), got \(result)")
        }
        XCTAssertEqual(steps.count, 3, "Init → read → overwrite must be fully sequential")
    }

    // MARK: - Group (sequential: true) becomes atomic node

    func testGroupSequential_becomesAtomicNode() {
        let ast: PipelineGraph = .sequence([
            .group(sequential: true, gate: false, .sequence([
                stateSet(slotA, value: opaqueLeaf("X")),
                stateSet(slotB, value: opaqueLeaf("Y")),
            ])),
            opaqueLeaf("After"),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(steps) = result else {
            return XCTFail("Expected .sequential, got \(result)")
        }

        XCTAssertEqual(steps.count, 2, "Group(sequential) should be one node + 'After'")
    }

    // MARK: - Group (sequential: false, gate: false) is transparent

    func testGroupNonSequentialNonGate_isTransparent() {
        let ast: PipelineGraph = .sequence([
            .group(sequential: false, gate: false, .sequence([
                stateSet(slotA, value: opaqueLeaf("X")),
                stateSet(slotB, value: opaqueLeaf("Y")),
            ])),
            model(instructions: "Read both", readingSlot: slotA),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(levels) = result else {
            return XCTFail("Expected .sequential, got \(result)")
        }
        XCTAssertEqual(levels.count, 2, "Transparent group: writes parallel, then model")

        guard case let .parallel(tasks) = levels[0] else {
            return XCTFail("Expected .parallel at level 0, got \(levels[0])")
        }
        XCTAssertEqual(tasks.count, 2, "Two independent writes should be parallelized through transparent group")
    }

    // MARK: - Gate forces all subsequent nodes to wait

    func testGate_blocksAllSubsequentNodes() {
        let ast: PipelineGraph = .sequence([
            .group(sequential: true, gate: true, opaqueLeaf("PolicyCheck")),
            stateSet(slotA, value: opaqueLeaf("X")),
            stateSet(slotB, value: opaqueLeaf("Y")),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(levels) = result else {
            return XCTFail("Expected .sequential, got \(result)")
        }
        XCTAssertEqual(levels.count, 2, "Gate → then parallel writes")

        if case .parallel = levels[0] {
            XCTFail("Gate node should not be parallelized with subsequent nodes")
        }
    }

    // MARK: - Guardrail default gated behavior

    func testExplicitGate_producesGroupWithGate() {
        let ast: PipelineGraph = .sequence([
            .group(sequential: true, gate: true, opaqueLeaf("PolicyCheck")),
            stateSet(slotA, value: opaqueLeaf("After")),
            stateSet(slotB, value: opaqueLeaf("Also After")),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(levels) = result else {
            return XCTFail("Expected .sequential, got \(result)")
        }

        XCTAssertEqual(levels.count, 2, "Guardrail gate → then parallel writes")

        guard case let .parallel(parallelTasks) = levels[1] else {
            return XCTFail("Expected .parallel at level 1 after gate, got \(levels[1])")
        }
        XCTAssertEqual(parallelTasks.count, 2, "Writes after gate should be parallel with each other")
    }

    // MARK: - Gate does not affect nodes before it

    func testGate_doesNotAffectPriorNodes() {
        let ast: PipelineGraph = .sequence([
            stateSet(slotA, value: opaqueLeaf("Before")),
            .group(sequential: true, gate: true, opaqueLeaf("PolicyCheck")),
            stateSet(slotB, value: opaqueLeaf("After")),
        ])

        let result = compiler.compile(ast)

        guard case let .sequential(levels) = result else {
            return XCTFail("Expected .sequential, got \(result)")
        }
        XCTAssertGreaterThanOrEqual(levels.count, 3,
            "Should have at least 3 levels: before, gate, after")
    }

    // MARK: - Group codable round-trip in AST

    func testGroupAST_JSONRoundTrip() throws {
        let ast: PipelineGraph = .group(sequential: true, gate: true, .sequence([
            opaqueLeaf("PolicyCheck"),
            .leaf(.opaque(typeName: "Check")),
        ]))

        let data = try ast.encoded()
        let decoded = try PipelineGraph.decode(from: data)
        XCTAssertEqual(decoded, ast)
    }

    // MARK: - Compilation benchmark

    private func makeBenchGraph(slotCount: Int) -> PipelineGraph {
        let slots = (0..<slotCount).map { _ in UUID() }
        var items: [PipelineGraph] = []
        for slot in slots {
            items.append(.leaf(.executionStateSet(
                id: slot, valueTypeName: "String",
                value: .leaf(.just(valueTypeName: "String", jsonUTF8: "\"v\"")),
                debugLabel: nil,
                writeKind: .commit
            )))
        }
        let readAll: PipelineGraph = .sequence(
            slots.map { .leaf(.executionStateGet(id: $0, valueTypeName: "String", debugLabel: nil, defaultJSON: "\"\"")) }
        )
        items.append(.leaf(.model(
            config: ModelConfig(
                outputTypeName: "String",
                    traits: [],
                streamingReplySlotID: nil,
                contextItemsSlotID: slots.first
            ),
            arguments: ["systemPrompt": .systemPrompt("merge")]
        )))
        return .sequence(items)
    }

    func testCompilationBenchmark() {
        let sizes = [100, 500, 1_000, 2_000]
        let iterations = 50

        for size in sizes {
            let graph = makeBenchGraph(slotCount: size)
            for _ in 0..<5 { _ = compiler.compile(graph) }

            var best = Double.infinity
            for _ in 0..<3 {
                let start = Date().timeIntervalSinceReferenceDate
                for _ in 0..<iterations {
                    _ = compiler.compile(graph)
                }
                let elapsed = Date().timeIntervalSinceReferenceDate - start
                best = min(best, elapsed)
            }
            let avgMs = (best / Double(iterations)) * 1_000
            print("  compile \(size) slots × \(iterations): best-of-3 avg \(String(format: "%.3f", avgMs))ms")
        }
    }
}
