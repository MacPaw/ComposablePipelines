//
//  DelegateStreamingIntegrationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL
import PipelineCompiler
import ExecutionEngine
import ComposablePipelines
import DelegateAgent

/// Phase 3.8 — the delegate status stream end-to-end at the data-contract level: a `.delegate` walk emits
/// primitive `delegateSubagent` events, which are carried (as a host's transport would carry them) and
/// folded client-side into a `DelegateSnapshot`. Asserts FIFO ordering, correct keying by run-ID path,
/// and that folding yields one consistent snapshot.
///
/// (A real transport needs a running host; the payload is primitives — `[Int]`/`String`/
/// `Int` — which round-trip trivially, so this exercises everything but the transport.)
final class DelegateStreamingIntegrationTests: XCTestCase {

    private struct StreamingDelegate: Pipeline {
        typealias Output = [String?]
        @State var tasks: [String] = []
        @State var task: String = ""
        init(seed: [String]) { self._tasks = State(wrappedValue: seed) }
        var body: some Pipeline {
            $tasks.set(tasks)
            Delegate(tasks: $tasks, taskInput: $task, budget: .init(total: 2, leafReserve: 0)) {
                Model<String>().input { $task.get() }
            }
        }
    }

    func testSubagentStatusStreamsFifoAndFoldsToSnapshot() async throws {
        // budget 2 over 3 tasks → indices 0,1 run; index 2 refused.
        let lowered = StreamingDelegate(seed: ["a", "b", "c"]).lowered()
        let graph = PipelineCompiler(optimizations: [.parallelize]).compile(lowered.graph)

        let wire = WireLog()
        _ = try await PipelineWalker(executor: EchoExecutor()).run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions),
            contextProviders: lowered.contextProviders,
            observingExecution: { event in
                // Mirror the wire: forward primitives exactly as HandleDelegateEvent would carry them.
                if case let .delegateSubagent(e) = event {
                    wire.append(path: e.path, phase: e.phase, cost: e.cost, epoch: e.epoch)
                }
            }
        )

        let events = wire.events

        // FIFO, per subagent: a `running` is observed before that subagent's `completed`.
        for path in [[0], [1]] {
            let running = events.firstIndex { $0.path == path && $0.phase == "running" }
            let completed = events.firstIndex { $0.path == path && $0.phase == "completed" }
            XCTAssertNotNil(running)
            XCTAssertNotNil(completed)
            XCTAssertLessThan(running!, completed!, "running must precede completed for \(path)")
        }
        // The over-budget subagent is reported refused and never completes.
        XCTAssertTrue(events.contains { $0.path == [2] && $0.phase == "refused" })
        XCTAssertFalse(events.contains { $0.path == [2] && $0.phase == "completed" })

        // Fold the streamed primitives client-side, keyed by run-ID path.
        let sink = DelegateStatusSink()
        for event in events {
            await sink.publish(path: event.path, phaseRawValue: event.phase, cost: event.cost)
        }
        let snapshot = await sink.snapshot(epoch: events.map(\.epoch).max() ?? 0)

        XCTAssertEqual(snapshot.status(for: .root.child(0))?.phase, .completed)
        XCTAssertEqual(snapshot.status(for: .root.child(1))?.phase, .completed)
        XCTAssertEqual(snapshot.status(for: .root.child(2))?.phase, .refused)
        XCTAssertEqual(snapshot.statuses.count, 3, "one folded status per subagent, keyed by path")
    }
}

private struct WireLog: Sendable {
    final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var events: [(path: [Int], phase: String, cost: Int, epoch: Int)] = []
    }
    let storage = Storage()
    var events: [(path: [Int], phase: String, cost: Int, epoch: Int)] { storage.lock.withLock { storage.events } }
    func append(path: [Int], phase: String, cost: Int, epoch: Int) {
        storage.lock.withLock { storage.events.append((path, phase, cost, epoch)) }
    }
}

private struct EchoExecutor: Executor {
    func runModel(config: ModelConfig, arguments: ModelArguments, onDelta: (@Sendable (String) -> Void)?) async throws -> ExecutionValue {
        let input: String
        if let message = arguments.message, let data = try? JSONEncoder().encode(message) {
            input = (try? JSONDecoder().decode(String.self, from: data)) ?? String(decoding: data, as: UTF8.self)
        } else { input = "" }
        return try JSONEncoder().encode("echo:\(input)")
    }
}
