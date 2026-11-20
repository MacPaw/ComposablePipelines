//
//  DelegateSpikeTests.swift
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

/// Phase 0.2 — the go/no-go spike for the whole reuse strategy. **Result: GO.** A delegate can be
/// expressed with only existing primitives — a `ClientTask` can host a nested `PipelineRunner.run`,
/// each child pipeline gets its own isolated `ExecutionContext`, and the parent gathers the distilled
/// returns. No new primitive is required for fan-out/gather.
///
/// Two working shapes, with a sharp distinction that shaped the design:
///
/// 1. **`ForEach` fan-out (compile-once).** A `ForEach` over the sub-tasks, each iteration a
///    `ClientTask` that runs a child, accumulating into a shared `@State` slot — exactly the
///    `BatchSummaryPipeline` shape. Works when the graph is compiled **once** (`walker.run`).
///
/// 2. **Single dispatch `ClientTask` (reactive-safe).** One `ClientTask` fans out to all children
///    (here concurrently via a `TaskGroup`) and returns the whole array atomically. This survives
///    **reactive re-lowering** (`PipelineRunner.run`) because it commits exactly once.
///
/// Finding: the `ForEach`-accumulator shape does **not** survive `PipelineRunner.run` — reactive
/// re-lowering re-emits the unrolled `ForEach` after the first commit and the run stalls at one
/// iteration. Since the real delegate derives its fan-out width from produced values (reactive), the
/// dispatch helper (shape 2) is the one to promote in Phase 2.1 — not the raw `ForEach` accumulator.
final class DelegateSpikeTests: XCTestCase {

    // MARK: - Shape 1: ForEach fan-out, compiled once

    func testForEachHostsNestedPipelineRunnerAndGathers() async throws {
        let executor = SpikeExecutor()
        let tasks = ["alpha", "beta", "gamma"]

        let result = try await runCompileOnce(
            DelegateForEachSpike(tasks: tasks, childExecutor: executor), executor: executor)
        let gathered = try JSONDecoder().decode([String].self, from: result)

        XCTAssertEqual(gathered, ["answer:alpha", "answer:beta", "answer:gamma"],
                       "each sub-task must be solved by its own nested child run and gathered in order")
    }

    // MARK: - Shape 2: single dispatch ClientTask, reactive-safe

    func testDispatchClientTaskFloodsAndGathersReactively() async throws {
        let executor = SpikeExecutor()
        let tasks = (0..<12).map { "t\($0)" }

        // PipelineRunner.run drives the full reactive re-lowering loop — the shape the real delegate uses.
        let result = try await PipelineRunner.run(
            DelegateDispatchSpike(tasks: tasks, childExecutor: executor), executor: executor)
        let gathered = try JSONDecoder().decode([String].self, from: result)

        XCTAssertEqual(gathered, tasks.map { "answer:\($0)" },
                       "a single dispatch task must flood all children and gather them in order")
    }

    // MARK: - Compile-once runner (mirrors PipelineRun.runOnce, which lives in a sibling target)

    private func runCompileOnce<P: Pipeline>(
        _ pipeline: P, executor: any Executor
    ) async throws -> ExecutionValue {
        let lowered = pipeline.lowered()
        let graph = PipelineCompiler(optimizations: [.parallelize]).compile(lowered.graph)
        return try await PipelineWalker(executor: executor).run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions),
            contextProviders: lowered.contextProviders
        )
    }
}

// MARK: - The smallest possible subagent

/// A single-turn worker: one `Model` turn requesting the shared delegate model, distilled to a short
/// string. Each `PipelineRunner.run` of this gets its own isolated `ExecutionContext`.
private struct DelegateWorkerSpike: Pipeline {
    typealias Output = String
    let task: String

    @State var answer = ""

    var body: some Pipeline {
        $answer.set {
            Model<String>()
                .systemPrompt("Answer the sub-task in one short line.")
                .requirements(DelegateModelConfig.resourceRequirements)
                .message(task)
        }
        $answer.get()
    }
}

// MARK: - Shape 1: ForEach + accumulator (compile-once)

private struct DelegateForEachSpike: Pipeline {
    typealias Output = [String]
    let tasks: [String]
    let childExecutor: any Executor

    @State var gathered: [String] = []

    var body: some Pipeline {
        ForEach(in: tasks) { task in
            $gathered.set {
                ClientTask(input: $gathered) { [childExecutor] prior in
                    let distilled = try await runWorker(task, executor: childExecutor)
                    return prior + [distilled]
                }
            }
        }
        $gathered.get()
    }
}

// MARK: - Shape 2: single dispatch ClientTask (reactive-safe)

private struct DelegateDispatchSpike: Pipeline {
    typealias Output = [String]
    let childExecutor: any Executor

    @State var tasks: [String]
    @State var gathered: [String] = []

    init(tasks: [String], childExecutor: any Executor) {
        self._tasks = State(wrappedValue: tasks)
        self.childExecutor = childExecutor
    }

    var body: some Pipeline {
        $gathered.set {
            ClientTask(input: $tasks) { [childExecutor] tasks in
                // Flood all children concurrently; collect by index so the gather stays ordered.
                try await withThrowingTaskGroup(of: (Int, String).self) { group in
                    for (index, task) in tasks.enumerated() {
                        group.addTask { (index, try await runWorker(task, executor: childExecutor)) }
                    }
                    var results = [String](repeating: "", count: tasks.count)
                    for try await (index, answer) in group { results[index] = answer }
                    return results
                }
            }
        }
        $gathered.get()
    }
}

// MARK: - Shared helpers

/// Run one subagent as a fully isolated nested pipeline and return its distilled string.
private func runWorker(_ task: String, executor: any Executor) async throws -> String {
    let output = try await PipelineRunner.run(DelegateWorkerSpike(task: task), executor: executor)
    return (try? JSONDecoder().decode(String.self, from: output)) ?? ""
}

/// Deterministic stand-in: echoes the message as `answer:<message>`. `ScriptedExecutor` lives in a
/// sibling test target, so the spike ships its own tiny executor.
private struct SpikeExecutor: Executor {
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
        return try JSONEncoder().encode("answer:\(input)")
    }
}
