//
//  DelegateSelfWalkerTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineCompiler
@testable import ExecutionEngine

/// Self-cloning — Step 3 (the walker). A `.delegate(child: .selfRecursion)` leaf re-runs the enclosing
/// **root** graph per subtask via the walker's self-delegate capability, sharing **one** spawn budget
/// across the whole self-tree. These tests drive the real `PipelineWalker` (no hand-written recursion)
/// to prove the leaf resolves at runtime and the shared budget makes an unbounded self-tree finite.
final class DelegateSelfWalkerTests: XCTestCase {

    private let taskSlot = UUID()
    private let tasksSlot = UUID()

    /// Thread-safe model-call counter for the scripted backend.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func inc() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    func testUnboundedSelfRecursionTerminatesThroughTheWalker() async throws {
        // Root: set a fixed 2-task list, then self-recurse over it. Re-running the root re-sets the
        // same non-empty list every level, so there is NO data base case — only the shared budget can
        // stop it. Completing at all proves `.selfRecursion` re-runs the root and the budget bounds it.
        let graph: PipelineGraph = .sequence([
            .leaf(.executionStateSet(
                id: tasksSlot, valueTypeName: "Array<String>",
                value: .leaf(.just(valueTypeName: "Array<String>", jsonUTF8: #"["a","b"]"#)),
                debugLabel: "tasks", writeKind: .commit)),
            .leaf(.delegate(
                child: .selfRecursion, tasksSlotID: tasksSlot, taskInputSlotID: taskSlot,
                budgetTotal: 7, leafReserve: 0, inherit: .isolated)),
        ])
        let compiled = PipelineCompiler().compile(graph)
        let executor = ScriptedExecutor { _ in ScriptedExecutor.string("x") }

        let out = try await PipelineWalker(executor: executor).run(graph: compiled)

        // The top delegate gathered an array (its two subagents' recursive results) — non-empty JSON.
        XCTAssertFalse(out.isEmpty, "an unbounded self-delegate run terminated and produced a gathered result")
    }

    /// Thread-safe collector of forwarded `.delegateSubagent` events.
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(path: [Int], phase: String, epoch: Int)] = []
        func record(_ path: [Int], _ phase: String, _ epoch: Int) {
            lock.withLock { events.append((path, phase, epoch)) }
        }
        var all: [(path: [Int], phase: String, epoch: Int)] { lock.withLock { events } }
    }

    /// Regression: subagent observation must reach **arbitrary recursion depth**. Before the fix, nested
    /// delegate runs were spawned without an observer and stamped only a single-element `[index]` path, so
    /// the client only ever saw the root delegate's direct children — the whole multi-level `DelegateRunID`
    /// machinery was unreachable. The walker now forwards `.delegateSubagent` events up and stamps a full
    /// hierarchical path, so a self-tree that recurses ≥ 2 levels emits events with path length ≥ 2.
    func testNestedSubagentObservationReachesTheRootObserver() async throws {
        let graph: PipelineGraph = .sequence([
            .leaf(.executionStateSet(
                id: tasksSlot, valueTypeName: "Array<String>",
                value: .leaf(.just(valueTypeName: "Array<String>", jsonUTF8: #"["a","b"]"#)),
                debugLabel: "tasks", writeKind: .commit)),
            .leaf(.delegate(
                child: .selfRecursion, tasksSlotID: tasksSlot, taskInputSlotID: taskSlot,
                budgetTotal: 7, leafReserve: 0, inherit: .isolated)),
        ])
        let compiled = PipelineCompiler().compile(graph)
        let executor = ScriptedExecutor { _ in ScriptedExecutor.string("x") }
        let collector = EventCollector()

        _ = try await PipelineWalker(executor: executor).run(
            graph: compiled,
            observingExecution: { event in
                if case let .delegateSubagent(e) = event { collector.record(e.path, e.phase, e.epoch) }
            }
        )

        let events = collector.all
        XCTAssertFalse(events.isEmpty, "the root delegate's subagent events must reach the observer")
        XCTAssertTrue(events.allSatisfy { !$0.path.isEmpty }, "every subagent has a non-empty path")
        XCTAssertTrue(events.contains { $0.path.count >= 2 },
                      "a nested subagent's event (hierarchical path length ≥ 2) must reach the root observer")
        // Paths are hierarchical: a depth-2 path's parent prefix is itself an observed depth-1 subagent.
        let depthOnePaths = Set(events.filter { $0.path.count == 1 }.map { $0.path })
        for event in events where event.path.count == 2 {
            XCTAssertTrue(depthOnePaths.contains([event.path[0]]),
                          "nested path \(event.path) extends an observed parent path")
        }
        XCTAssertTrue(events.allSatisfy { (0...2).contains($0.epoch) }, "epochs are membership/warm-up/flood waves")
    }

    func testSharedBudgetBoundsSelfRecursionSpawns() async throws {
        // Root does one model call per level, then self-recurses. Every spawned delegate is exactly one
        // root re-run (one model call), so the shared budget caps total spawns — hence total model
        // calls ≤ budget + 1 (the extra 1 is the top-level run, which is not itself a spawn).
        let budgetTotal = 8
        let graph: PipelineGraph = .sequence([
            .leaf(.executionStateSet(
                id: tasksSlot, valueTypeName: "Array<String>",
                value: .leaf(.just(valueTypeName: "Array<String>", jsonUTF8: #"["a","b","c"]"#)),
                debugLabel: "tasks", writeKind: .commit)),
            .leaf(.modelInput(
                config: ModelConfig(outputTypeName: "String"), arguments: [:],
                input: .leaf(.just(valueTypeName: "String", jsonUTF8: "\"go\"")))),
            .leaf(.delegate(
                child: .selfRecursion, tasksSlotID: tasksSlot, taskInputSlotID: taskSlot,
                budgetTotal: budgetTotal, leafReserve: 0, inherit: .isolated)),
        ])
        let compiled = PipelineCompiler().compile(graph)
        let counter = Counter()
        let executor = ScriptedExecutor { _ in counter.inc(); return ScriptedExecutor.string("x") }

        _ = try await PipelineWalker(executor: executor).run(graph: compiled)

        XCTAssertGreaterThan(counter.value, 1, "self-recursion actually spawned delegates that re-ran the root")
        XCTAssertLessThanOrEqual(counter.value, budgetTotal + 1,
                                 "the shared budget bounds total spawns across the whole self-tree")
    }
}
