//
//  DelegateIsolationTests.swift
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

/// Phase 2.3 — per-subagent state isolation. A `.delegate` child is *one* lowered template, so every
/// task-run references the **same** `@State` slot ids. The proof of isolation: each run gets its own
/// `ExecutionContext`, so even a wide concurrent flood whose children each write and read a shared
/// scratch slot never cross-contaminates — every result reflects only its own task.
///
/// (Path isolation via `PathJail` is not exercised: delegate v1 subagents are model-only and touch no
/// filesystem, so there is no jail to escape. State isolation is the property that matters here.)
final class DelegateIsolationTests: XCTestCase {

    private struct IsolationPipeline: Pipeline {
        typealias Output = [String?]
        let seed: [String]

        @State var tasks: [String] = []
        @State var task: String = ""
        @State var scratch: String = ""

        var body: some Pipeline {
            $tasks.set(seed)
            Delegate(tasks: $tasks, taskInput: $task, budget: .init(total: 128, leafReserve: 0)) {
                // Two steps sharing the scratch slot id across every task-run: copy the seeded task
                // into scratch, then echo scratch. If contexts weren't isolated, concurrent runs would
                // clobber each other's scratch and the echoes would come out wrong.
                $scratch.set { Model<String>().input { $task.get() } }
                Model<String>().input { $scratch.get() }
            }
        }
    }

    func testConcurrentSubagentsDoNotShareState() async throws {
        let seed = (0..<24).map { "t\($0)" }
        let results = try await run(IsolationPipeline(seed: seed))

        // Each child: scratch = "echo:<task>", then echo scratch = "echo:echo:<task>".
        let expected = seed.map { "echo:echo:\($0)" as String? }
        XCTAssertEqual(results, expected,
                       "each subagent sees only its own scratch — no cross-contamination under concurrency")
    }

    private func run(_ pipeline: some Pipeline) async throws -> [String?] {
        let lowered = pipeline.lowered()
        let graph = PipelineCompiler(optimizations: [.parallelize]).compile(lowered.graph)
        let out = try await PipelineWalker(executor: EchoExecutor()).run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions),
            contextProviders: lowered.contextProviders
        )
        return try JSONDecoder().decode([String?].self, from: out)
    }
}

/// Echoes the message as `echo:<message>`.
private struct EchoExecutor: Executor {
    func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        let input: String
        if let message = arguments.message, let data = try? JSONEncoder().encode(message) {
            input = (try? JSONDecoder().decode(String.self, from: data))
                ?? String(decoding: data, as: UTF8.self)
        } else {
            input = ""
        }
        return try JSONEncoder().encode("echo:\(input)")
    }
}
