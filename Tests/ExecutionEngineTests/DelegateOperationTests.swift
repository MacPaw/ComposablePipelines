//
//  DelegateOperationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineCompiler
@testable import ExecutionEngine

/// Step B — the native `.delegate` operation walked agent-side. A hand-built graph seeds a task list,
/// then a `.delegate` leaf runs a child template once per task (each in an isolated scope, task seeded
/// into the child's input slot) through the *same* executor, gathering the distilled results.
final class DelegateOperationTests: XCTestCase {

    private let taskSlot = UUID()
    private let tasksSlot = UUID()

    /// Child template: a single model step whose message is the per-task input slot value.
    private func childGraph() -> PipelineGraph {
        .leaf(.modelInput(
            config: ModelConfig(outputTypeName: "String"),
            arguments: [:],
            input: .leaf(.executionStateGet(
                id: taskSlot, valueTypeName: "String", debugLabel: "task", defaultJSON: "\"\""))
        ))
    }

    private func delegateGraph(tasksJSON: String, budgetTotal: Int, leafReserve: Int) -> PipelineGraph {
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
                budgetTotal: budgetTotal,
                leafReserve: leafReserve,
                inherit: .isolated
            )),
        ])
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [([Int], String)] = []
        var values: [([Int], String)] { lock.withLock { storage } }
        func append(_ value: ([Int], String)) { lock.withLock { storage.append(value) } }
    }

    private func run(_ graph: PipelineGraph) async throws -> [String?] {
        let compiled = PipelineCompiler().compile(graph)
        let executor = ScriptedExecutor { call in ScriptedExecutor.string("answer:\(call.input)") }
        let out = try await PipelineWalker(executor: executor).run(graph: compiled)
        return try JSONDecoder().decode([String?].self, from: out)
    }

    func testDelegateRunsChildPerTaskAndGathersInOrder() async throws {
        let results = try await run(delegateGraph(tasksJSON: #"["a","b","c"]"#, budgetTotal: 10, leafReserve: 0))
        XCTAssertEqual(results, ["answer:a", "answer:b", "answer:c"],
                       "each task is solved by its own isolated child run, gathered in task order")
    }

    func testDelegateRefusesTasksBeyondBudget() async throws {
        // total 2, leafReserve 0: warm-up spends 1, one more granted → 2 run, the third refused (null).
        let results = try await run(delegateGraph(tasksJSON: #"["a","b","c"]"#, budgetTotal: 2, leafReserve: 0))
        XCTAssertEqual(results, ["answer:a", "answer:b", nil],
                       "the budget caps how many subagents the delegate may spawn")
    }

    func testEmptyTaskListYieldsEmptyGather() async throws {
        let results = try await run(delegateGraph(tasksJSON: "[]", budgetTotal: 10, leafReserve: 0))
        XCTAssertEqual(results, [])
    }

    func testDelegateStripsReasoningFromChildOutput() async throws {
        // A reasoning model emits chain-of-thought before the answer; the delegate must gather only the
        // distilled answer, not the transcript.
        let compiled = PipelineCompiler().compile(
            delegateGraph(tasksJSON: #"["a","b"]"#, budgetTotal: 10, leafReserve: 0))
        let executor = ScriptedExecutor { call in
            ScriptedExecutor.string("<think>long private reasoning about \(call.input)</think>answer:\(call.input)")
        }
        let out = try await PipelineWalker(executor: executor).run(graph: compiled)
        let results = try JSONDecoder().decode([String?].self, from: out)

        XCTAssertEqual(results, ["answer:a", "answer:b"],
                       "chain-of-thought is stripped; only the distilled answer is gathered")
    }

    // MARK: - Capability inheritance (opt-in: tools + memory, isolated by default)

    private let toolTaskID = UUID()

    /// Child template: call a client tool (`.clientAction`) with the per-task input.
    private func toolChildGraph() -> PipelineGraph {
        .leaf(.clientAction(
            taskID: toolTaskID,
            input: .leaf(.executionStateGet(
                id: taskSlot, valueTypeName: "String", debugLabel: "task", defaultJSON: "\"\""))
        ))
    }

    /// Child template: query memory with the per-task input.
    private func memoryChildGraph() -> PipelineGraph {
        .leaf(.memoryQuery(
            quality: .quick,
            query: .leaf(.executionStateGet(
                id: taskSlot, valueTypeName: "String", debugLabel: "task", defaultJSON: "\"\""))
        ))
    }

    private func delegateGraph(
        child: PipelineGraph,
        tasksJSON: String,
        inherit: DelegateInheritance
    ) -> PipelineGraph {
        .sequence([
            .leaf(.executionStateSet(
                id: tasksSlot, valueTypeName: "Array<String>",
                value: .leaf(.just(valueTypeName: "Array<String>", jsonUTF8: tasksJSON)),
                debugLabel: "tasks", writeKind: .commit)),
            .leaf(.delegate(
                child: .embedded(child), tasksSlotID: tasksSlot, taskInputSlotID: taskSlot,
                budgetTotal: 10, leafReserve: 0, inherit: inherit)),
        ])
    }

    func testDelegateSubagentsInheritClientTools() async throws {
        // Each subagent calls a client tool; with `inherit: .tools` the parent's provider is forwarded
        // into every isolated child run (isolated state, explicitly granted capability).
        let compiled = PipelineCompiler().compile(
            delegateGraph(child: toolChildGraph(), tasksJSON: #"["a","b"]"#, inherit: .tools))
        let executor = ScriptedExecutor { _ in ScriptedExecutor.string("unused") }
        let out = try await PipelineWalker(executor: executor).run(
            graph: compiled,
            clientActionProvider: { _, input in
                let task = try JSONDecoder().decode(String.self, from: input)
                return try JSONEncoder().encode("tool(\(task))")
            }
        )
        let results = try JSONDecoder().decode([String?].self, from: out)
        XCTAssertEqual(results, ["tool(a)", "tool(b)"],
                       "delegate subagents inherit the parent run's client tools")
    }

    func testDelegateSubagentsInheritMemory() async throws {
        // Each subagent queries memory; with `inherit: .memory` the parent's provider is forwarded
        // into every isolated child run.
        let compiled = PipelineCompiler().compile(
            delegateGraph(child: memoryChildGraph(), tasksJSON: #"["a","b"]"#, inherit: .memory))
        let executor = ScriptedExecutor { _ in ScriptedExecutor.string("unused") }
        let out = try await PipelineWalker(executor: executor).run(
            graph: compiled,
            memoryProvider: EchoMemory()
        )
        // Each subagent's memory query resolves through the inherited provider (output is a per-task
        // list of context items carrying the recalled text).
        let gathered = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(gathered.contains("recalled:a"), "subagent a queried the inherited memory store")
        XCTAssertTrue(gathered.contains("recalled:b"), "subagent b queried the inherited memory store")
    }

    func testDelegateSubagentsIsolatedByDefault() async throws {
        // With the default `.isolated` mask, a subagent's client-tool call is denied even though the
        // parent run supplies a provider. The denial is *contained* (graceful): the child fails, so its
        // gathered result is `nil` — proof the capability was withheld, not silently forwarded (an
        // inherited provider would have surfaced the echoed input instead of nil).
        let compiled = PipelineCompiler().compile(
            delegateGraph(child: toolChildGraph(), tasksJSON: #"["a"]"#, inherit: .isolated))
        let executor = ScriptedExecutor { _ in ScriptedExecutor.string("unused") }
        let out = try await PipelineWalker(executor: executor).run(
            graph: compiled,
            clientActionProvider: { _, input in input })
        let results = try JSONDecoder().decode([String?].self, from: out)
        XCTAssertEqual(results, [nil],
                       "an isolated subagent cannot reach the parent's client tools — the call is denied, yielding nil")
    }

    func testDelegateEmitsSubagentStatusEvents() async throws {
        // budget 2: warm-up (1) + one more granted → indices 0,1 run; index 2 is refused.
        let graph = delegateGraph(tasksJSON: #"["a","b","c"]"#, budgetTotal: 2, leafReserve: 0)
        let compiled = PipelineCompiler().compile(graph)
        let executor = ScriptedExecutor { call in ScriptedExecutor.string("answer:\(call.input)") }

        let events = EventBox()
        _ = try await PipelineWalker(executor: executor).run(
            graph: compiled,
            observingExecution: { event in
                if case let .delegateSubagent(e) = event { events.append((e.path, e.phase)) }
            }
        )

        let captured = events.values
        XCTAssertTrue(captured.contains { $0 == ([0], "running") })
        XCTAssertTrue(captured.contains { $0 == ([1], "running") })
        XCTAssertTrue(captured.contains { $0 == ([2], "refused") }, "the over-budget task is reported refused")
        XCTAssertTrue(captured.contains { $0 == ([0], "completed") })
        XCTAssertTrue(captured.contains { $0 == ([1], "completed") })
        XCTAssertFalse(captured.contains { $0 == ([2], "completed") }, "a refused task never completes")
    }

    func testDelegateContainsSubagentFailureAndReportsFailedPhase() async throws {
        // The subagent for task "b" throws. The delegate must survive: gather `nil` for "b", keep the
        // others, and report "b" as `failed` (never `completed`) — one weak subagent can't sink it.
        let compiled = PipelineCompiler().compile(
            delegateGraph(tasksJSON: #"["a","b","c"]"#, budgetTotal: 10, leafReserve: 0))
        let executor = ScriptedExecutor { call in
            if call.input == "b" { throw DelegateChildFailure.boom }
            return ScriptedExecutor.string("answer:\(call.input)")
        }

        let events = EventBox()
        let out = try await PipelineWalker(executor: executor).run(
            graph: compiled,
            observingExecution: { event in
                if case let .delegateSubagent(e) = event { events.append((e.path, e.phase)) }
            })

        let results = try JSONDecoder().decode([String?].self, from: out)
        XCTAssertEqual(results, ["answer:a", nil, "answer:c"],
                       "a failing subagent contributes nil and does not abort the delegate")

        let captured = events.values
        XCTAssertTrue(captured.contains { $0 == ([1], "failed") }, "the erroring subagent is reported failed")
        XCTAssertFalse(captured.contains { $0 == ([1], "completed") }, "a failed subagent never completes")
        XCTAssertTrue(captured.contains { $0 == ([0], "completed") })
        XCTAssertTrue(captured.contains { $0 == ([2], "completed") })
    }

    func testCompletedSubagentReportsApproximateCost() async throws {
        // The scripted answer for "a" is "answer:a"; a completed subagent reports the distilled
        // result's size as a rough cost (0 for the initial running/refused emissions).
        let compiled = PipelineCompiler().compile(
            delegateGraph(tasksJSON: #"["a"]"#, budgetTotal: 10, leafReserve: 0))
        let executor = ScriptedExecutor { call in ScriptedExecutor.string("answer:\(call.input)") }

        let events = CostEventBox()
        _ = try await PipelineWalker(executor: executor).run(
            graph: compiled,
            observingExecution: { event in
                if case let .delegateSubagent(e) = event { events.append((e.path, e.phase, e.cost)) }
            })

        let completed = events.values.first { $0.path == [0] && $0.phase == "completed" }
        XCTAssertEqual(completed?.cost, "answer:a".count,
                       "a completed subagent reports the distilled result size as a rough cost")
    }
}

private enum DelegateChildFailure: Error { case boom }

/// Captures delegate subagent events with their cost for the cost assertion.
private final class CostEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(path: [Int], phase: String, cost: Int)] = []
    var values: [(path: [Int], phase: String, cost: Int)] { lock.withLock { storage } }
    func append(_ value: (path: [Int], phase: String, cost: Int)) { lock.withLock { storage.append(value) } }
}

/// Stand-in memory provider: echoes each query back as a single recalled entry.
private struct EchoMemory: MemoryProvider {
    func add(_ entry: MemoryEntry) async throws {}
    func retrieve(id: String) async throws -> MemoryEntry? { nil }
    func query(_ text: String, quality: MemoryQueryQuality) async throws -> [MemoryEntry] {
        [MemoryEntry(id: "e", text: "recalled:\(text)")]
    }
}
