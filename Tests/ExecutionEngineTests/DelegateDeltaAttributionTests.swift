//
//  DelegateDeltaAttributionTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineCompiler
@testable import ExecutionEngine

/// Which subagent a streamed chunk came from.
///
/// Siblings run concurrently and their output interleaves, so `taskID` identifies the *step* that emitted
/// a chunk but not who ran it. A host showing per-subagent turns has no way to reconstruct the second
/// half from anything else on the wire, which is why the path rides along on the event.
///
/// - Author: Claude
final class DelegateDeltaAttributionTests: XCTestCase {

    private final class DeltaBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(path: [Int], text: String)] = []

        var values: [(path: [Int], text: String)] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func append(_ path: [Int], _ text: String) {
            lock.lock(); defer { lock.unlock() }
            storage.append((path, text))
        }
    }

    private let tasksSlot = UUID()
    private let taskSlot = UUID()

    private func childGraph() -> PipelineGraph {
        .leaf(.modelInput(
            config: ModelConfig(outputTypeName: "String"),
            arguments: [:],
            input: .leaf(.executionStateGet(
                id: taskSlot, valueTypeName: "String", debugLabel: "task", defaultJSON: "\"\""))
        ))
    }

    private func delegateGraph(tasksJSON: String) -> PipelineGraph {
        .sequence([
            .leaf(.executionStateSet(
                id: tasksSlot,
                valueTypeName: "Array<String>",
                value: .leaf(.just(valueTypeName: "Array<String>", jsonUTF8: tasksJSON)),
                debugLabel: "tasks",
                writeKind: .commit
            )),
            .leaf(.delegate(
                child: .embedded(childGraph()),
                tasksSlotID: tasksSlot,
                taskInputSlotID: taskSlot,
                budgetTotal: 10,
                leafReserve: 0,
                inherit: .isolated
            )),
        ])
    }

    func testEachSubagentsDeltaCarriesItsOwnPath() async throws {
        let deltas = DeltaBox()
        let compiled = PipelineCompiler().compile(delegateGraph(tasksJSON: #"["a","b","c"]"#))
        let executor = ScriptedExecutor { call in ScriptedExecutor.string("answer:\(call.input)") }

        _ = try await PipelineWalker(executor: executor).run(
            graph: compiled,
            observingExecution: { event in
                if case let .modelOutputDelta(_, text, path) = event { deltas.append(path, text) }
            }
        )

        // One child per task, each at its own index under the delegate root.
        let byPath = Dictionary(
            uniqueKeysWithValues: deltas.values.map { ($0.path, $0.text) })
        XCTAssertEqual(byPath[[0]], "answer:a")
        XCTAssertEqual(byPath[[1]], "answer:b")
        XCTAssertEqual(byPath[[2]], "answer:c")
    }

    func testAParentsOwnTurnCarriesAnEmptyPath() async throws {
        let deltas = DeltaBox()
        let graph = PipelineGraph.leaf(.modelInput(
            config: ModelConfig(outputTypeName: "String"),
            arguments: [:],
            input: .leaf(.just(valueTypeName: "String", jsonUTF8: "\"hello\""))
        ))
        let executor = ScriptedExecutor { call in ScriptedExecutor.string("answer:\(call.input)") }

        _ = try await PipelineWalker(executor: executor).run(
            graph: PipelineCompiler().compile(graph),
            observingExecution: { event in
                if case let .modelOutputDelta(_, text, path) = event { deltas.append(path, text) }
            }
        )

        XCTAssertEqual(deltas.values.map(\.path), [[]],
                       "a turn outside any delegate is the root's own, not a subagent's")
    }
}
