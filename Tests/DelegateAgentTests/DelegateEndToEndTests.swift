//
//  DelegateEndToEndTests.swift
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

/// Step B.8 — the whole agent-walked delegate, authored with the `Delegate` DSL block, from lowering
/// through compilation to execution. Proves the declarative path end-to-end: the delegate fans out over
/// a runtime task list, runs each child in an isolated scope (so each sees only its own task) through
/// the shared executor, bounds the fan-out with the budget, and gathers in order.
final class DelegateEndToEndTests: XCTestCase {

    private struct DelegatePipeline: Pipeline {
        typealias Output = [String?]
        let seed: [String]
        let budget: DelegateBudget

        @State var questions: [String] = []
        @State var question: String = ""

        var body: some Pipeline {
            $questions.set(seed)
            Delegate(tasks: $questions, taskInput: $question, budget: budget) {
                Model<String>().systemPrompt("Answer.").input { $question.get() }
            }
        }
    }

    func testDelegateBlockFansOutAndGathersInOrder() async throws {
        let results = try await run(
            DelegatePipeline(seed: ["a", "b", "c"], budget: .init(total: 16, leafReserve: 0)))
        XCTAssertEqual(results, ["answer:a", "answer:b", "answer:c"],
                       "each subagent sees only its own task and the results gather in order")
    }

    func testDelegateBlockRefusesTasksBeyondBudget() async throws {
        // total 2: warm-up spends 1, one more granted → 2 run, the third refused (nil).
        let results = try await run(
            DelegatePipeline(seed: ["a", "b", "c"], budget: .init(total: 2, leafReserve: 0)))
        XCTAssertEqual(results, ["answer:a", "answer:b", nil])
    }

    // MARK: - Compile-once runner (the pipeline is linear: set tasks, then the delegate leaf)

    private func run(_ pipeline: some Pipeline) async throws -> [String?] {
        let lowered = pipeline.lowered()
        let graph = PipelineCompiler(optimizations: [.parallelize]).compile(lowered.graph)
        let executor = EchoExecutor()
        let out = try await PipelineWalker(executor: executor).run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions),
            contextProviders: lowered.contextProviders
        )
        return try JSONDecoder().decode([String?].self, from: out)
    }
}

/// Echoes the message as `answer:<message>` — enough to prove each child saw its own seeded task.
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
        return try JSONEncoder().encode("answer:\(input)")
    }
}
