//
//  DelegateRecursionSpikeTests.swift
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

/// Phase 0.3 — extends the fan-out spike to one level of recursion (agents spawning agents).
/// **Result: composes.** The dispatch shape from 0.2 nests with no new machinery: a branch subagent
/// is *itself* a dispatch pipeline that floods a set of leaf grandchildren, and the whole two-level
/// tree runs through nested `PipelineRunner.run` + nested `ThrowingTaskGroup`s.
///
/// Findings (commit body):
/// - Recursion is just composition — a subagent's worker closure runs another `PipelineRunner.run`,
///   and each nested run keeps its own isolated `ExecutionContext`.
/// - Nested `ThrowingTaskGroup` parallelism behaves: grandchildren of different branches run
///   concurrently, results stay correctly ordered per branch, and the tree terminates.
/// - There is **no** built-in bound on tree size here — an unbounded recursion is expressible. That
///   is exactly what Phase 1 (spawn budget + termination guarantee) must contain.
final class DelegateRecursionSpikeTests: XCTestCase {

    func testTwoLevelRecursionComposesAndGathers() async throws {
        let executor = RecursionSpikeExecutor()
        let branches = ["b0", "b1", "b2"]
        let leavesPerBranch = 4

        let result = try await PipelineRunner.run(
            DelegateBranchDispatch(branches: branches, leavesPerBranch: leavesPerBranch, executor: executor),
            executor: executor
        )
        let gathered = try JSONDecoder().decode([String].self, from: result)

        // Each branch aggregates its own ordered leaves; the parent aggregates the branches in order.
        let expected = branches.map { branch in
            let leaves = (0..<leavesPerBranch).map { "answer:\(branch).l\($0)" }
            return "\(branch):[\(leaves.joined(separator: ","))]"
        }
        XCTAssertEqual(gathered, expected)
    }

    func testRecursionScalesWithoutDeadlock() async throws {
        let executor = RecursionSpikeExecutor()
        let branches = (0..<8).map { "b\($0)" }

        let result = try await PipelineRunner.run(
            DelegateBranchDispatch(branches: branches, leavesPerBranch: 6, executor: executor),
            executor: executor
        )
        let gathered = try JSONDecoder().decode([String].self, from: result)

        XCTAssertEqual(gathered.count, branches.count, "every branch subtree must complete")
    }
}

// MARK: - Leaf subagent (grandchild): one model turn

private struct DelegateLeafSpike: Pipeline {
    typealias Output = String
    let task: String

    @State var answer = ""

    var body: some Pipeline {
        $answer.set {
            Model<String>()
                .requirements(DelegateModelConfig.resourceRequirements)
                .systemPrompt("Answer in one line.")
                .message(task)
        }
        $answer.get()
    }
}

// MARK: - Branch subagent (child): floods leaves, aggregates them

/// A subagent that is *itself* a delegate: it fans out to `leavesPerBranch` leaf grandchildren and folds
/// their distilled returns into a single line. Run via a nested `PipelineRunner.run` from the parent.
private struct DelegateBranchSpike: Pipeline {
    typealias Output = String
    let childExecutor: any Executor

    @State var branch: String
    @State var leafCount: Int
    @State var aggregate = ""

    init(branch: String, leavesPerBranch: Int, executor: any Executor) {
        self._branch = State(wrappedValue: branch)
        self._leafCount = State(wrappedValue: leavesPerBranch)
        self.childExecutor = executor
    }

    var body: some Pipeline {
        $aggregate.set {
            ClientTask(input: $branch) { [childExecutor, count = leafCount] branch in
                let leaves = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                    for index in 0..<count {
                        group.addTask { [childExecutor] in
                            let answer = try await runLeaf("\(branch).l\(index)", executor: childExecutor)
                            return (index, answer)
                        }
                    }
                    var results = [String](repeating: "", count: count)
                    for try await (index, answer) in group { results[index] = answer }
                    return results
                }
                return "\(branch):[\(leaves.joined(separator: ","))]"
            }
        }
        $aggregate.get()
    }
}

// MARK: - Parent: floods branch subagents (each of which floods its own leaves)

private struct DelegateBranchDispatch: Pipeline {
    typealias Output = [String]
    let childExecutor: any Executor

    @State var branches: [String]
    @State var leavesPerBranch: Int
    @State var gathered: [String] = []

    init(branches: [String], leavesPerBranch: Int, executor: any Executor) {
        self._branches = State(wrappedValue: branches)
        self._leavesPerBranch = State(wrappedValue: leavesPerBranch)
        self.childExecutor = executor
    }

    var body: some Pipeline {
        $gathered.set {
            ClientTask(input: $branches) { [childExecutor, perBranch = leavesPerBranch] branches in
                try await withThrowingTaskGroup(of: (Int, String).self) { group in
                    for (index, branch) in branches.enumerated() {
                        group.addTask { [childExecutor] in
                            // Recursion: the branch subagent is itself a delegate, run as its own pipeline.
                            let output = try await PipelineRunner.run(
                                DelegateBranchSpike(branch: branch, leavesPerBranch: perBranch, executor: childExecutor),
                                executor: childExecutor
                            )
                            let distilled = (try? JSONDecoder().decode(String.self, from: output)) ?? ""
                            return (index, distilled)
                        }
                    }
                    var results = [String](repeating: "", count: branches.count)
                    for try await (index, answer) in group { results[index] = answer }
                    return results
                }
            }
        }
        $gathered.get()
    }
}

// MARK: - Helpers

private func runLeaf(_ task: String, executor: any Executor) async throws -> String {
    let output = try await PipelineRunner.run(DelegateLeafSpike(task: task), executor: executor)
    return (try? JSONDecoder().decode(String.self, from: output)) ?? ""
}

/// Echoes the message as `answer:<message>` (self-contained; ScriptedExecutor is in a sibling target).
private struct RecursionSpikeExecutor: Executor {
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
