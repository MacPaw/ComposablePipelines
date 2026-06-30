//
//  ExecutionEngineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineCompiler
@testable import ExecutionEngine

final class ExecutionEngineTests: XCTestCase {

    let engine = PipelineWalker(executor: MockExecutor())

    // MARK: - Graph Builders

    private func constant(_ value: String) -> PipelineExecutionGraph {
        .task(.init(operation: .constant(valueTypeName: "String", jsonUTF8: "\"\(value)\"")))
    }

    private func stateGet(_ id: UUID, defaultJSON: String = "\"\"") -> PipelineExecutionGraph {
        .task(.init(operation: .stateGet(slotID: id, valueTypeName: "String", debugLabel: nil, defaultJSON: defaultJSON)))
    }

    private func stateSet(_ id: UUID, value: String) -> PipelineExecutionGraph {
        .task(
            .init(
                operation: .stateSet(
                    slotID: id,
                    valueTypeName: "String",
                    value: constant(value),
                    debugLabel: nil,
                    writeKind: .commit
                )
            )
        )
    }

    // MARK: - Helpers

    /// Runs `graph` collecting all events, returns (result, events).
    private func run(
        _ graph: PipelineExecutionGraph,
        clientActions: [UUID: @Sendable (ExecutionValue) async throws -> ExecutionValue] = [:],
        initialSlots: [UUID: ExecutionValue] = [:]
    ) async throws -> (result: ExecutionValue, events: [ExecutionEvent]) {
        var events: [ExecutionEvent] = []
        let clientActionProvider = clientActions.isEmpty
            ? nil
            : PipelineWalker.clientActionProvider(from: clientActions)
        let result = try await engine.run(
            graph: graph,
            clientActionProvider: clientActionProvider,
            initialSlots: initialSlots,
            observingExecution: { events.append($0) }
        )
        return (result, events)
    }

    /// Decode a JSON-encoded `ExecutionValue` into a typed Swift value.
    private func decode<T: Decodable>(_ type: T.Type, _ data: ExecutionValue) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// JSON-encode a typed value into an `ExecutionValue`.
    private func encode<T: Encodable>(_ value: T) throws -> ExecutionValue {
        try JSONEncoder().encode(value)
    }

    /// Last `.stateUpdated` value for a given slot across an event list.
    private func lastSlotValue(_ slotID: UUID, in events: [ExecutionEvent]) -> ExecutionValue? {
        events.reversed().lazy.compactMap {
            if case .stateUpdated(let u) = $0, u.slotID == slotID { return u.value }
            return nil
        }.first
    }

    // MARK: - Constant

    func testConstant_decodesString() async throws {
        let (result, _) = try await run(constant("hello"))
        XCTAssertEqual(try decode(String.self, result), "hello")
    }

    func testConstant_decodesBool() async throws {
        let graph: PipelineExecutionGraph = .task(.init(operation: .constant(valueTypeName: "Bool", jsonUTF8: "true")))
        let (result, _) = try await run(graph)
        XCTAssertEqual(try decode(Bool.self, result), true)
    }

    func testConstant_decodesInt() async throws {
        let graph: PipelineExecutionGraph = .task(.init(operation: .constant(valueTypeName: "Int", jsonUTF8: "42")))
        let (result, _) = try await run(graph)
        XCTAssertEqual(try decode(Int.self, result), 42)
    }

    // MARK: - State

    func testStateSet_returnsWrittenValue() async throws {
        let (result, _) = try await run(stateSet(UUID(), value: "world"))
        XCTAssertEqual(try decode(String.self, result), "world")
    }

    func testStateSet_appearsInStateUpdatedEvent() async throws {
        let slotID = UUID()
        let (_, events) = try await run(stateSet(slotID, value: "track-me"))
        let raw = try XCTUnwrap(lastSlotValue(slotID, in: events))
        XCTAssertEqual(try decode(String.self, raw), "track-me")
    }

    func testInitialSlots_areVisibleViaClientAction() async throws {
        let slotID = UUID()
        let taskID = UUID()
        let (result, _) = try await run(
            .task(.init(operation: .clientAction(taskID: taskID, input: stateGet(slotID)))),
            clientActions: [taskID: { input in input }],
            initialSlots: [slotID: try encode("injected")]
        )
        XCTAssertEqual(try decode(String.self, result), "injected")
    }

    // MARK: - Sequential

    func testSequential_returnsLastStepResult() async throws {
        let slotID = UUID()
        let (result, _) = try await run(.sequential([
            stateSet(slotID, value: "first"),
            stateSet(slotID, value: "last"),
        ]))
        XCTAssertEqual(try decode(String.self, result), "last")
    }

    func testSequential_executesStepsInOrder() async throws {
        let slotID = UUID()
        let (_, events) = try await run(.sequential([
            stateSet(slotID, value: "first"),
            stateSet(slotID, value: "second"),
        ]))
        let slotHistory = events.compactMap { event -> String? in
            if case .stateUpdated(let u) = event, u.slotID == slotID {
                return try? JSONDecoder().decode(String.self, from: u.value)
            }
            return nil
        }
        XCTAssertEqual(slotHistory.first, "first")
        XCTAssertEqual(slotHistory.last, "second")
    }

    // MARK: - Early Return

    func testEarlyReturn_exitsWithReturnValue() async throws {
        let (result, _) = try await run(.sequential([
            .returnWith(constant("early")),
            constant("unreachable"),
        ]))
        XCTAssertEqual(try decode(String.self, result), "early")
    }

    func testEarlyReturn_doesNotExecuteSubsequentSteps() async throws {
        let slotID = UUID()
        let (_, events) = try await run(.sequential([
            stateSet(slotID, value: "before"),
            .returnWith(constant("exit")),
            stateSet(slotID, value: "unreachable"),
        ]))
        let raw = try XCTUnwrap(lastSlotValue(slotID, in: events))
        XCTAssertEqual(try decode(String.self, raw), "before")
    }

    func testEarlyReturn_afterPredecessorDoesNotExecuteSubsequentSteps() async throws {
        let slotID = UUID()
        let (result, events) = try await run(.sequential([
            constant("checked"),
            .returnWith(constant("blocked")),
            stateSet(slotID, value: "unreachable"),
        ]))

        XCTAssertEqual(try decode(String.self, result), "blocked")
        XCTAssertNil(lastSlotValue(slotID, in: events))
    }

    // MARK: - Parallel

    func testParallel_allBranchesComplete() async throws {
        let slotA = UUID()
        let slotB = UUID()
        let (_, events) = try await run(.parallel([
            stateSet(slotA, value: "alpha"),
            stateSet(slotB, value: "beta"),
        ]))
        let rawA = try XCTUnwrap(lastSlotValue(slotA, in: events))
        let rawB = try XCTUnwrap(lastSlotValue(slotB, in: events))
        XCTAssertEqual(try decode(String.self, rawA), "alpha")
        XCTAssertEqual(try decode(String.self, rawB), "beta")
    }

    func testParallel_emitsGroupStartedAndCompleted() async throws {
        let (_, events) = try await run(.parallel([
            constant("a"),
            constant("b"),
        ]))
        XCTAssertTrue(events.contains { if case .parallelGroupStarted = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .parallelGroupCompleted = $0 { return true }; return false })
    }

    func testParallel_executedCount_countsEachBranch() async throws {
        let slotA = UUID()
        let slotB = UUID()
        let graph = PipelineExecutionGraph.sequential([
            stateSet(slotA, value: "alpha"),
            .parallel([
                stateSet(slotA, value: "alpha"),
                stateSet(slotB, value: "beta"),
            ]),
        ])
        let (_, events) = try await run(graph)
        let completed = events.compactMap { event -> (Int, Int)? in
            if case .parallelGroupCompleted(let c, let e) = event { return (c, e) }
            return nil
        }.first
        let (count, executed) = try XCTUnwrap(completed)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(executed, 2, "Both branches execute (no cross-pass execution memo)")
    }

    func testParallel_stateUpdates_comesAfterGroupCompleted() async throws {
        let slotA = UUID()
        let slotB = UUID()
        let (_, events) = try await run(.parallel([
            stateSet(slotA, value: "alpha"),
            stateSet(slotB, value: "beta"),
        ]))
        let completedIdx = try XCTUnwrap(events.firstIndex { if case .parallelGroupCompleted = $0 { return true }; return false })
        let updatedAIdx  = try XCTUnwrap(events.firstIndex { if case .stateUpdated(let u) = $0, u.slotID == slotA { return true }; return false })
        let updatedBIdx  = try XCTUnwrap(events.firstIndex { if case .stateUpdated(let u) = $0, u.slotID == slotB { return true }; return false })
        XCTAssertGreaterThan(updatedAIdx, completedIdx)
        XCTAssertGreaterThan(updatedBIdx, completedIdx)
    }

    // MARK: - Client Action

    func testStateGet_missingSlot_returnsEmptyJSONString() async throws {
        let slotID = UUID()
        let taskID = UUID()
        let (result, _) = try await run(
            .task(.init(operation: .clientAction(taskID: taskID, input: stateGet(slotID)))),
            clientActions: [taskID: { input in input }]
        )
        // Absent slot must yield JSON empty string ("\"\""), not raw empty Data.
        XCTAssertEqual(result, Data("\"\"".utf8))
    }

    func testClientAction_emitsStateUpdatedEvent() async throws {
        let taskID = UUID()
        let (_, events) = try await run(
            .task(.init(operation: .clientAction(taskID: taskID, input: constant("ping")))),
            clientActions: [taskID: { input in input }]
        )
        let hasUpdate = events.contains {
            if case .stateUpdated(let u) = $0, u.slotID == taskID, u.valueTypeName == "ClientAction" { return true }
            return false
        }
        XCTAssertTrue(hasUpdate, "clientAction must emit a stateUpdated event keyed by taskID")
    }

    func testClientAction_callsRegisteredClosure() async throws {
        let taskID = UUID()
        let (result, _) = try await run(
            .task(.init(operation: .clientAction(taskID: taskID, input: constant("ping")))),
            clientActions: [taskID: { input in
                let str = (try? JSONDecoder().decode(String.self, from: input)) ?? ""
                return Data("\"pong: \(str)\"".utf8)
            }]
        )
        XCTAssertEqual(try decode(String.self, result), "pong: ping")
    }

    func testClientAction_throwsMissingAction_whenNotRegistered() async throws {
        let taskID = UUID()
        do {
            _ = try await run(.task(.init(operation: .clientAction(taskID: taskID, input: .empty))))
            XCTFail("Expected missingClientAction error")
        } catch let error as ExecutionError {
            guard case .missingClientAction(let id) = error else {
                return XCTFail("Unexpected ExecutionError case: \(error)")
            }
            XCTAssertEqual(id, taskID)
        }
    }

    func testStep_emitsFailedEventOnThrow() async throws {
        let taskID = UUID()
        var events: [ExecutionEvent] = []
        do {
            _ = try await engine.run(
                graph: .task(.init(id: taskID, operation: .clientAction(taskID: taskID, input: .empty))),
                observingExecution: { events.append($0) }
            )
            XCTFail("Expected missingClientAction error")
        } catch {}
        XCTAssertTrue(
            events.contains { if case .stepFailed(let i, _, _) = $0, i.taskID == taskID { return true }; return false },
            "stepFailed must be emitted when a task throws"
        )
    }

    // MARK: - Memoization

    func testClientAction_twoStepsWithSameInput_eachInvokesClosure() async throws {
        actor CallTracker { var count = 0; func increment() -> Int { count += 1; return count } }
        let tracker = CallTracker()
        let taskID = UUID()
        let graph = PipelineExecutionGraph.sequential([
            .task(.init(id: taskID, operation: .clientAction(taskID: taskID, input: constant("x")))),
            .task(.init(id: UUID(), operation: .clientAction(taskID: taskID, input: constant("x")))),
        ])
        let (_, events) = try await run(
            graph,
            clientActions: [taskID: { _ in try JSONEncoder().encode(await tracker.increment()) }]
        )
        let calls = await tracker.count
        XCTAssertEqual(calls, 2, "Each `.task` runs its own clientAction invocation")
        XCTAssertFalse(events.contains { if case .stepSkipped = $0 { return true }; return false })
    }

    func testMemo_differentInputsAreNotCached() async throws {
        actor CallTracker { var count = 0; func increment() -> Int { count += 1; return count } }
        let tracker = CallTracker()
        let taskID = UUID()
        let graph = PipelineExecutionGraph.sequential([
            .task(.init(id: UUID(), operation: .clientAction(taskID: taskID, input: constant("a")))),
            .task(.init(id: UUID(), operation: .clientAction(taskID: taskID, input: constant("b")))),
        ])
        _ = try await run(
            graph,
            clientActions: [taskID: { _ in try JSONEncoder().encode(await tracker.increment()) }]
        )
        let calls = await tracker.count
        XCTAssertEqual(calls, 2, "Different inputs must not share a cache entry")
    }

    // MARK: - Step Events

    func testStep_emitsStartedThenCompleted() async throws {
        let taskID = UUID()
        let task = PipelineExecutionGraph.Task(id: taskID, operation: .constant(valueTypeName: "String", jsonUTF8: "\"hi\""))
        let (_, events) = try await run(.task(task))

        let stepEvents = events.filter {
            if case .stepStarted(let i) = $0, i.taskID == taskID { return true }
            if case .stepCompleted(let i, _, _) = $0, i.taskID == taskID { return true }
            return false
        }
        XCTAssertEqual(stepEvents.count, 2)
        guard case .stepStarted = stepEvents[0] else { return XCTFail("Expected stepStarted first") }
        guard case .stepCompleted = stepEvents[1] else { return XCTFail("Expected stepCompleted second") }
    }

    func testStep_completedCarriesResultPreview() async throws {
        let (_, events) = try await run(constant("hello"))
        let preview = events.compactMap { event -> String? in
            if case .stepCompleted(_, let p, _) = event { return p }
            return nil
        }.first
        // Preview is the raw JSON bytes decoded as UTF-8 string: "hello" (with JSON quotes).
        XCTAssertEqual(preview, "\"hello\"")
    }

    func testExecution_completedEventIsLast() async throws {
        let (_, events) = try await run(constant("x"))
        guard case .executionCompleted = events.last else {
            return XCTFail("Last event must be .executionCompleted, got \(String(describing: events.last))")
        }
    }

    func testDraftStateWrite_emitsStateUpdatedButDoesNotInvokeGraphProvider() async throws {
        let slotID = UUID()
        var graphProviderCalls = 0
        var committedBatches: [[StateUpdate]] = []
        let draftSet: PipelineExecutionGraph = .task(
            .init(
                operation: .stateSet(
                    slotID: slotID,
                    valueTypeName: "String",
                    value: constant("preview"),
                    debugLabel: nil,
                    writeKind: .draft
                )
            )
        )
        var events: [ExecutionEvent] = []
        let result = try await engine.run(
            graph: draftSet,
            onCommittedBatch: { committedBatches.append($0) },
            graphProvider: { _ in
                graphProviderCalls += 1
                return nil
            },
            observingExecution: { events.append($0) }
        )
        XCTAssertEqual(graphProviderCalls, 0, "Draft writes must not schedule graphProvider")
        XCTAssertEqual(committedBatches.count, 1)
        XCTAssertEqual(committedBatches[0].count, 1)
        XCTAssertEqual(committedBatches[0][0].kind, .draft)
        XCTAssertEqual(committedBatches[0][0].slotID, slotID)
        let kinds = events.compactMap { event -> StateWriteKind? in
            if case .stateUpdated(let u) = event { return u.kind }
            return nil
        }
        XCTAssertEqual(kinds, [StateWriteKind.draft])
        XCTAssertEqual(try decode(String.self, result), "preview")
    }

    // MARK: - Re-execution

    func testReexecution_emitsReexecutionStartedBeforeSecondPass() async throws {
        let slotID = UUID()
        var triggered = false
        var allEvents: [ExecutionEvent] = []

        _ = try await engine.run(
            graph: stateSet(slotID, value: "v1"),
            graphProvider: { _ in
                if !triggered {
                    triggered = true
                    return ReexecutionGraph(graph: self.stateSet(slotID, value: "v2"))
                }
                return nil
            },
            observingExecution: { allEvents.append($0) }
        )

        let reexecIdx = allEvents.firstIndex { if case .reexecutionStarted = $0 { return true }; return false }
        XCTAssertNotNil(reexecIdx, "Expected .reexecutionStarted event")
    }

    func testReexecution_createsProgressScopePerPass() async throws {
        let slotID = UUID()
        var triggered = false
        var allEvents: [ExecutionEvent] = []

        _ = try await engine.run(
            graph: stateSet(slotID, value: "v1"),
            graphProvider: { _ in
                if !triggered {
                    triggered = true
                    return ReexecutionGraph(graph: self.stateSet(slotID, value: "v2"))
                }
                return nil
            },
            observingExecution: { allEvents.append($0) }
        )

        let progressStarts = allEvents.compactMap { event -> ExecutionProgressUpdate? in
            guard case .resourceProgressUpdated(let update) = event, update.fraction == 0 else {
                return nil
            }
            return update
        }

        XCTAssertEqual(progressStarts.map(\.iteration), [0, 1])
        XCTAssertEqual(Set(progressStarts.map(\.runID)).count, 1)
    }

    func testReexecution_respectsMaxDepthGuard() async throws {
        var allEvents: [ExecutionEvent] = []
        var slotIDs: [UUID] = [UUID()]

        // Each pass appends one more `stateSet` at a fresh ordinal so the prefix replay covers
        // already-recorded ordinals while the new tail task actually runs and writes a fresh
        // slot — guaranteeing a flush and a graphProvider call every iteration. Without this,
        // ordinal replay would short-circuit re-execution after the first pass.
        func graph(stepCount: Int) -> PipelineExecutionGraph {
            .sequential((0..<stepCount).map { stateSet(slotIDs[$0], value: "p\($0)") })
        }

        let limitedEngine = PipelineWalker(executor: MockExecutor(), maxReexecutionDepth: 3)
        _ = try await limitedEngine.run(
            graph: graph(stepCount: 1),
            graphProvider: { _ in
                slotIDs.append(UUID())
                return ReexecutionGraph(graph: graph(stepCount: slotIDs.count))
            },
            observingExecution: { allEvents.append($0) }
        )

        let reexecCount = allEvents.filter { if case .reexecutionStarted = $0 { return true }; return false }.count
        XCTAssertEqual(reexecCount, 3, "Should stop after maxReexecutionDepth iterations")
    }

    /// When re-execution shrinks the graph to only `returnWith(stateGet)`, the get can fall under
    /// the prefix-skip window (ordinal `< activeSkipCount`). Skipped `stateGet` must still read the
    /// slot — otherwise `EarlyReturn` carries empty `Data()` and JSON `Output` decode fails (playground REPL).
    func testReexecution_skippedTerminalStateGet_stillReturnsSlotBytes() async throws {
        let slot = UUID()
        final class Phase: @unchecked Sendable { var n = 0 }
        let phase = Phase()
        let terminalGet = stateGet(slot)
        let full: PipelineExecutionGraph = .sequential([
            stateSet(slot, value: "final"),
            .returnWith(terminalGet),
        ])
        let tailOnly: PipelineExecutionGraph = .returnWith(terminalGet)

        final class BatchHolder: @unchecked Sendable {
            var batch: [StateUpdate] = []
        }
        let holder = BatchHolder()
        let result = try await engine.run(
            graph: full,
            onCommittedBatch: { holder.batch = $0 },
            graphProvider: { _ in
                guard !holder.batch.isEmpty, phase.n == 0 else { return nil }
                phase.n += 1
                return ReexecutionGraph(graph: tailOnly)
            }
        )
        XCTAssertEqual(try decode(String.self, result), "final")
    }

    /// Re-lowering committed state writes can collapse the remaining graph to independent
    /// `stateGet` leaves. The compiler may execute those reads as one parallel level; when that
    /// level is terminal, the pipeline output is still the last branch in source order.
    func testParallelTerminalStateGets_returnsLastBranchValue() async throws {
        let first = UUID()
        let second = UUID()
        let graph: PipelineExecutionGraph = .parallel([
            stateGet(first),
            stateGet(second),
        ])

        let result = try await engine.run(
            graph: graph,
            initialSlots: [
                first: try encode("first"),
                second: try encode("second"),
            ]
        )

        XCTAssertEqual(try decode(String.self, result), "second")
    }

    func testReexecution_terminalParallelStateGets_returnsLastBranchValue() async throws {
        let first = UUID()
        let second = UUID()
        var providedTerminalReads = false

        let result = try await engine.run(
            graph: .parallel([
                stateSet(first, value: "first"),
                stateSet(second, value: "second"),
            ]),
            graphProvider: { _ in
                guard !providedTerminalReads else { return nil }
                providedTerminalReads = true
                return ReexecutionGraph(graph: .parallel([
                    self.stateGet(first),
                    self.stateGet(second),
                ]))
            }
        )

        XCTAssertEqual(try decode(String.self, result), "second")
    }

    func testReexecution_prefixSkip_skipsUnchangedClientAction() async throws {
        actor CallTracker { var count = 0; func increment() -> Int { count += 1; return count } }
        let tracker = CallTracker()
        let slotID = UUID()
        let taskID = UUID()
        var triggered = false
        final class CommitHolder: @unchecked Sendable {
            var updates: [StateUpdate] = []
        }
        let commitHolder = CommitHolder()

        // Swap only after the slot write so the first graph’s clientAction finishes before re-exec.
        _ = try await engine.run(
            graph: .sequential([
                .task(.init(id: taskID, operation: .clientAction(taskID: taskID, input: constant("x")))),
                stateSet(slotID, value: "trigger"),
            ]),
            clientActionProvider: PipelineWalker.clientActionProvider(from: [
                taskID: { _ in try JSONEncoder().encode(await tracker.increment()) },
            ]),
            onCommittedBatch: { commitHolder.updates = $0 },
            graphProvider: { cursor in
                guard commitHolder.updates.contains(where: { $0.slotID == slotID }) else { return nil }
                commitHolder.updates = []
                if !triggered {
                    triggered = true
                    let graph: PipelineExecutionGraph = .sequential([
                        .task(.init(id: taskID, operation: .clientAction(taskID: taskID, input: self.constant("x")))),
                        self.stateSet(slotID, value: "done"),
                    ])
                    return ReexecutionGraph(graph: graph.droppingFirstSurfaceTasks(cursor.offset), appliedCursor: cursor)
                }
                return nil
            }
        )

        let calls = await tracker.count
        XCTAssertEqual(calls, 1, "Re-exec should prefix-skip the unchanged clientAction")
    }

    /// After a `.parallel` flush, remainder flattened op kinds may differ (e.g. DSL `switch`); engine must not require suffix structural equality.
    func testReexecution_afterParallelFlush_acceptsDifferentRemainderStructuralShape() async throws {
        let slot1 = UUID(), slot2 = UUID(), slot3 = UUID()

        let firstPass: PipelineExecutionGraph = .sequential([
            constant("go"),
            .parallel([
                stateSet(slot1, value: "billing"),
                stateSet(slot2, value: "other"),
            ]),
            .sequential([
                stateGet(slot1),
                stateGet(slot1),
                stateSet(slot3, value: "default-path"),
            ]),
        ])

        let secondPass: PipelineExecutionGraph = .sequential([
            constant("go"),
            .parallel([
                stateSet(slot1, value: "billing"),
                stateSet(slot2, value: "other"),
            ]),
            .sequential([
                stateGet(slot1),
                stateSet(slot2, value: "mid"),
                stateSet(slot3, value: "billing-path"),
            ]),
        ])

        var gaveSecondGraph = false
        var events: [ExecutionEvent] = []
        _ = try await engine.run(
            graph: firstPass,
            graphProvider: { _ in
                if !gaveSecondGraph {
                    gaveSecondGraph = true
                    return ReexecutionGraph(graph: secondPass)
                }
                return nil
            },
            observingExecution: { events.append($0) }
        )

        XCTAssertTrue(events.contains { if case .reexecutionStarted(1) = $0 { return true }; return false })
        let lastReply = try XCTUnwrap(lastSlotValue(slot3, in: events))
        XCTAssertEqual(try decode(String.self, lastReply), "billing-path")
    }

    func testReexecution_prefixReplayUsesOrdinalWithoutKeyComparison() async throws {
        let slotID = UUID()
        var switched = false
        var events: [ExecutionEvent] = []

        _ = try await engine.run(
            graph: stateSet(slotID, value: "v1"),
            graphProvider: { _ in
                guard !switched else { return nil }
                switched = true
                // Prefix task differs on pass 2; ordinal replay keeps the recorded prefix value.
                return ReexecutionGraph(graph: self.stateSet(slotID, value: "v2"))
            },
            observingExecution: { events.append($0) }
        )

        XCTAssertTrue(events.contains { if case .reexecutionStarted(1) = $0 { return true }; return false })
        let raw = try XCTUnwrap(lastSlotValue(slotID, in: events))
        XCTAssertEqual(try decode(String.self, raw), "v1")
    }
}
