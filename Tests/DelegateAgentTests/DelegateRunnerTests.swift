//
//  DelegateRunnerTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL
import ExecutionEngine
import ComposablePipelines
import DelegateAgent

/// Phase (agent-side hook, Step A) — `DelegateRunner` logic: it gathers subagents in order, refuses the
/// tail when the budget is too small, and — crucially — runs the first subagent to completion before
/// flooding the rest (the warm-then-flood contract that keeps the delegate on one shared model instance).
final class DelegateRunnerTests: XCTestCase {

    func testGathersAllSubagentsInOrder() async throws {
        let executor = RunnerExecutor()
        let budget = SpawnBudget(total: 10, leafReserve: 0)
        let tasks = ["a", "b", "c", "d"]

        let results = try await DelegateRunner.run(
            tasks: tasks,
            budget: budget,
            subagent: { try await solve($0, executor: executor) },
            exhausted: { "refused:\($0)" }
        )

        XCTAssertEqual(results, ["answer:a", "answer:b", "answer:c", "answer:d"])
    }

    func testBudgetRefusesTailSubagents() async throws {
        let executor = RunnerExecutor()
        // Warm-up spends 1; dispatch of the remaining 5 can grant only 2 more → 3 run, 3 refused.
        let budget = SpawnBudget(total: 3, leafReserve: 0)
        let tasks = ["a", "b", "c", "d", "e", "f"]

        let results = try await DelegateRunner.run(
            tasks: tasks,
            budget: budget,
            subagent: { try await solve($0, executor: executor) },
            exhausted: { "refused:\($0)" }
        )

        let solved = results.filter { $0.hasPrefix("answer:") }.count
        let refused = results.filter { $0.hasPrefix("refused:") }.count
        XCTAssertEqual(solved, 3, "budget caps how many subagents run")
        XCTAssertEqual(refused, 3)
        XCTAssertEqual(results[0], "answer:a", "the warm-up subagent always runs first")
    }

    func testWarmUpCompletesFirstSubagentBeforeFlood() async throws {
        let executor = RunnerExecutor()
        let recorder = EventRecorder()
        let budget = SpawnBudget(total: 10, leafReserve: 0)
        let tasks = ["a", "b", "c", "d"]

        _ = try await DelegateRunner.run(
            tasks: tasks,
            budget: budget,
            subagent: { task in
                await recorder.append("start:\(task)")
                let result = try await solve(task, executor: executor)
                await recorder.append("finish:\(task)")
                return result
            },
            exhausted: { "refused:\($0)" }
        )

        let events = await recorder.events
        let firstFinish = events.firstIndex(of: "finish:a")!
        let otherStarts = events.enumerated().filter { $0.element.hasPrefix("start:") && $0.element != "start:a" }
        for (index, event) in otherStarts {
            XCTAssertGreaterThan(index, firstFinish,
                                 "\(event) must start only after the warm-up subagent finished")
        }
    }
}

// MARK: - Helpers

private func solve(_ task: String, executor: any Executor) async throws -> String {
    let output = try await PipelineRunner.run(RunnerWorker(task: task), executor: executor)
    return (try? JSONDecoder().decode(String.self, from: output)) ?? ""
}

private struct RunnerWorker: Pipeline {
    typealias Output = String
    let task: String

    @State var answer = ""

    var body: some Pipeline {
        $answer.set {
            Model<String>().requirements(DelegateModelConfig.resourceRequirements).message(task)
        }
        $answer.get()
    }
}

private struct RunnerExecutor: Executor {
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

private actor EventRecorder {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}
