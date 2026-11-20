//
//  InGraphReactiveTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
import PipelineDSL
@testable import ExecutionEngine

/// Slot-driven reactive control flow evaluated **in-graph** by the walker. The point: these run via
/// `runOnce` — a single pass with **no** `graphProvider` (exactly what a delegate's static walk gets) —
/// so `While($bool)` iterates and `When($bool)` branches without any re-lowering.
final class InGraphReactiveTests: XCTestCase {

    private struct CounterLoop: Pipeline {
        typealias Output = Int
        @State var n = 0
        @State var keepGoing = false
        var body: some Pipeline {
            // The condition slot must be committed before the loop reads it (an unset slot reads false).
            $keepGoing.set { Run(id: "start") { true } }
            While($keepGoing) {
                $n.set { Run(input: $n) { $0 + 1 } }
                $keepGoing.set { Run(input: $n) { $0 < 3 } }
            }
            $n.get()
        }
    }

    func testWhileSlotIteratesWithoutGraphProvider() async throws {
        let (result, _) = try await PipelineRun.runOnce(CounterLoop(), executor: MockExecutor())
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: result), 3,
                       "the in-graph while loop iterated to termination with no re-lowering")
    }

    private struct BranchPick: Pipeline {
        typealias Output = String
        let flag: Bool
        @State var decided = false
        @State var out = ""
        var body: some Pipeline {
            $decided.set { Run(id: "seed") { [flag] in flag } }
            When($decided) {
                $out.set { Run(id: "t") { "then" } }
            } else: {
                $out.set { Run(id: "e") { "else" } }
            }
            $out.get()
        }
    }

    func testWhenSlotBranchesWithoutGraphProvider() async throws {
        let (thenResult, _) = try await PipelineRun.runOnce(BranchPick(flag: true), executor: MockExecutor())
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: thenResult), "then")

        let (elseResult, _) = try await PipelineRun.runOnce(BranchPick(flag: false), executor: MockExecutor())
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: elseResult), "else")
    }

    // MARK: - Reactive control flow INSIDE a delegate

    /// A delegate whose child runs a slot-driven `While` loop `iters` times. Each delegate runs isolated,
    /// via a nested walker with no `graphProvider` — so the loop iterating at all proves reactive
    /// control flow works inside a delegate (the whole point of the in-graph nodes for self-cloning
    /// agents).
    private struct DelegateWithReactiveChild: Pipeline {
        typealias Output = [Int?]
        @State var perDelegate: [Int] = []
        @State var iters: Int = 0     // seeded per delegate
        @State var count = 0
        @State var keepGoing = false
        var body: some Pipeline {
            $perDelegate.set([2, 3])
            Delegate(tasks: $perDelegate, taskInput: $iters, budget: .init(total: 8), inherit: [.tools]) {
                $keepGoing.set { Run($count, $iters) { c, it in c < it } }
                While($keepGoing) {
                    $count.set { Run(input: $count) { $0 + 1 } }
                    $keepGoing.set { Run($count, $iters) { c, it in c < it } }
                }
                $count.get()
            }
        }
    }

    func testDelegateChildRunsAReactiveLoop() async throws {
        let (result, _) = try await PipelineRun.runOnce(DelegateWithReactiveChild(), executor: MockExecutor())
        let counts = try JSONDecoder().decode([Int?].self, from: result)
        XCTAssertEqual(counts, [2, 3],
                       "each isolated delegate iterated its in-graph loop to its own seeded count")
    }
}
