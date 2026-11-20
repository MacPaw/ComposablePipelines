//
//  DelegateAggregationIntegrationTests.swift
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

/// Phase 4.4 — end-to-end: a delegate of **noisy** workers runs through the real execution path (each
/// answers the same question, a scripted backend makes the minority wrong), and aggregation recovers
/// the correct answer under every completion policy — while a single worker (the first result) is
/// wrong. This is the delegate's whole point: breadth-first flooding + aggregation beats one attempt.
final class DelegateAggregationIntegrationTests: XCTestCase {

    private struct NoisyDelegate: Pipeline {
        typealias Output = [String?]
        @State var tasks: [String] = Array(repeating: "What is the answer?", count: 5)
        @State var task: String = ""
        var body: some Pipeline {
            $tasks.set(tasks)
            Delegate(tasks: $tasks, taskInput: $task, budget: .init(total: 8, leafReserve: 0)) {
                Model<String>().input { $task.get() }
            }
        }
    }

    func testAggregationRecoversCorrectAnswerFromNoisyWorkers() async throws {
        // Scripted backend: the first two model calls (warm-up + one flooded) answer WRONG, the rest
        // answer RIGHT — so the delegate of 5 has a correct majority (3) despite noisy siblings.
        let lowered = NoisyDelegate().lowered()
        let graph = PipelineCompiler(optimizations: [.parallelize]).compile(lowered.graph)
        let out = try await PipelineWalker(executor: NoisyExecutor(wrongFirst: 2)).run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions),
            contextProviders: lowered.contextProviders
        )
        let answers = try JSONDecoder().decode([String?].self, from: out).compactMap { $0 }

        // Build distilled results; model "correct workers are more confident" so bestOf/firstGood work.
        let results = answers.enumerated().map { index, answer in
            DelegateResult(id: "\(index)", answer: answer, confidence: answer == "RIGHT" ? 0.9 : 0.4)
        }

        XCTAssertEqual(answers.filter { $0 == "RIGHT" }.count, 3, "correct majority")
        XCTAssertEqual(answers.filter { $0 == "WRONG" }.count, 2, "noisy minority")

        // A single worker (take the first) is wrong — the warm-up subagent answered WRONG.
        XCTAssertEqual(results.first?.answer, "WRONG", "the first single worker is wrong")

        // Every completion policy recovers the correct answer.
        XCTAssertEqual(DelegateAggregator.aggregate(results, policy: .quorum(3)).winner?.answer, "RIGHT")
        XCTAssertEqual(DelegateAggregator.aggregate(results, policy: .bestOf).winner?.answer, "RIGHT")
        XCTAssertEqual(DelegateAggregator.aggregate(results, policy: .firstGood(minConfidence: 0.8)).winner?.answer, "RIGHT")
    }
}

/// Answers `WRONG` for the first `wrongFirst` model calls, then `RIGHT`. The delegate's warm-then-flood
/// runs the warm-up subagent first, so result index 0 is deterministically one of the wrong ones.
private final class NoisyExecutor: Executor, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let wrongFirst: Int

    init(wrongFirst: Int) { self.wrongFirst = wrongFirst }

    func runModel(config: ModelConfig, arguments: ModelArguments, onDelta: (@Sendable (String) -> Void)?) async throws -> ExecutionValue {
        let index = lock.withLock { defer { calls += 1 }; return calls }
        return try JSONEncoder().encode(index < wrongFirst ? "WRONG" : "RIGHT")
    }
}
