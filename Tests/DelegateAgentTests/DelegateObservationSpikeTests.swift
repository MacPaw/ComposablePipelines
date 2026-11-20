//
//  DelegateObservationSpikeTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL
import PipelineCompiler
@_spi(Internals) import ExecutionEngine
import ComposablePipelines

/// Phase 3.1 — spike for the SwiftUI-style observation flows, run against isolated subagent runs
/// (a `PipelineWalker.run` per child, mirroring the `.delegate` operation).
///
/// Findings:
/// - **Ambient context flows DOWN with no new primitive.** Seeding extra slots (here a `contextItems`
///   slot alongside the task slot) into the child run is enough — `initialSlots` carries run scope,
///   budget, etc. down. `From`/`ContextItems` ride the same slot mechanism (3.3 will lower them).
/// - **Status can only flow UP through an observer sink, NOT through `@State`.** A child run owns its
///   own `ExecutionContext`; the parent cannot read the child's `@State` (it is gone once the run
///   returns — the parent gets only the final value). Live status is observable only by threading an
///   `observingExecution` sink into the child run. So the "PreferenceKey reduce" (3.4) must be a
///   sink-and-fold, not `@State`-up — this spike confirms the gap.
final class DelegateObservationSpikeTests: XCTestCase {

    // MARK: Ambient context down

    private struct AmbientChild: Pipeline {
        typealias Output = String
        @State var task = ""
        @State var ambient: [ContextItem] = []
        var body: some Pipeline {
            Model<String>().contextItems($ambient).input { $task.get() }
        }
    }

    func testAmbientContextFlowsDownViaSeededSlots() async throws {
        let child = AmbientChild()
        let lowered = child.lowered()
        let graph = PipelineCompiler().compile(lowered.graph)

        let ambient = [ContextItem(kind: .custom("scope"), source: .init(rawValue: "spike"), value: .string("SCOPED"))]
        let out = try await PipelineWalker(executor: SpyExecutor()).run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions),
            contextProviders: lowered.contextProviders,
            initialSlots: [
                child.$task.id: try JSONEncoder().encode("T"),
                child.$ambient.id: try JSONEncoder().encode(ambient),
            ]
        )
        let result = try JSONDecoder().decode(String.self, from: out)
        XCTAssertEqual(result, "task=T;ambient=SCOPED",
                       "both the task and the ambient context are seeded down into the isolated child")
    }

    // MARK: Status up (only via a sink)

    private struct StatusChild: Pipeline {
        typealias Output = String
        @State var status = ""
        @State var reply = ""
        var body: some Pipeline {
            $status.set("running")
            $reply.set { Model<String>().message("done") }
            $reply.get()
        }
    }

    func testStatusFlowsUpOnlyThroughAnObserverSink() async throws {
        let child = StatusChild()
        let lowered = child.lowered()
        let graph = PipelineCompiler().compile(lowered.graph)

        // A sink threaded into the child run captures its live status — this is the only way the
        // parent can observe a subagent's progress; the child's @State never crosses back on its own.
        let captured = StatusSink()
        _ = try await PipelineWalker(executor: SpyExecutor()).run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions),
            observingExecution: { event in
                if case let .stateUpdated(update) = event, update.slotID == child.$status.id {
                    captured.record((try? JSONDecoder().decode(String.self, from: update.value)) ?? "")
                }
            }
        )

        XCTAssertEqual(captured.values, ["running"],
                       "the child's mid-run status is observable only through the injected sink")
    }
}

private struct SpyExecutor: Executor {
    func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        let message: String
        if let msg = arguments.message, let data = try? JSONEncoder().encode(msg) {
            message = (try? JSONDecoder().decode(String.self, from: data)) ?? String(decoding: data, as: UTF8.self)
        } else {
            message = ""
        }
        let ambient = arguments.contextItems.compactMap { item -> String? in
            if case let .string(s) = item.value { return s }
            return nil
        }
        if ambient.isEmpty { return try JSONEncoder().encode(message) }
        return try JSONEncoder().encode("task=\(message);ambient=\(ambient.joined(separator: ","))")
    }
}

private final class StatusSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func record(_ value: String) { lock.withLock { storage.append(value) } }
}
