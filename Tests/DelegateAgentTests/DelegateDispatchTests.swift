//
//  DelegateDispatchTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import ExecutionEngine
import DelegateAgent

/// Phase 1.2 — the fan-out site enforces the budget and refuses at zero, so even an *unbounded*
/// recursion (every node tries to fan out, no depth cap) terminates purely because the budget is
/// monotonically non-increasing.
final class DelegateDispatchTests: XCTestCase {

    func testRefusesTailTasksWhenBudgetIsSmallerThanFanOut() async throws {
        let budget = SpawnBudget(total: 3, leafReserve: 0)
        let counter = SpawnCounter()

        let results = try await DelegateDispatch.dispatch(
            Array(0..<10),
            budget: budget,
            worker: { _, _ in await counter.increment(); return 1 },
            exhausted: { _ in 0 }
        )

        XCTAssertEqual(results, [1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
                       "only the first `granted` tasks spawn; the tail is refused with the exhausted value")
        let spawned = await counter.value
        XCTAssertEqual(spawned, 3, "no more than the budget may spawn")
    }

    func testLeavesMakeProgressEvenWhenDescentIsDrained() async throws {
        let budget = SpawnBudget(total: 6, leafReserve: 2)

        // Drain the entire descent pool (total - leafReserve = 4) via branch reservations.
        let drained = await budget.reserve(100)
        XCTAssertEqual(drained, 4)

        // Now fan out 5 leaves; only the 2 protected leaf slots remain, so exactly 2 run.
        let results = try await DelegateDispatch.dispatchLeaves(
            Array(0..<5),
            budget: budget,
            worker: { $0 * 10 },
            exhausted: { _ in -1 }
        )

        XCTAssertEqual(results, [0, 10, -1, -1, -1],
                       "leaf reserve guarantees leaves run even when descent is saturated")
    }

    func testUnboundedRecursionTerminatesUnderBudget() async throws {
        let total = 50
        let budget = SpawnBudget(total: total, leafReserve: 0)
        let delegate = RecursiveDelegate(counter: SpawnCounter(), fanOut: 4)

        // Every worker unconditionally tries to spawn `fanOut` children — nothing but the budget
        // bounds the tree. This must terminate and never exceed the cap.
        let results = try await DelegateDispatch.dispatch(
            Array(0..<delegate.fanOut),
            budget: budget,
            worker: delegate.run,
            exhausted: { _ in 0 }
        )

        let spawned = await delegate.counter.value
        XCTAssertGreaterThan(spawned, 0, "the delegate must actually do work")
        XCTAssertLessThanOrEqual(spawned, total, "total spawns must never exceed the budget cap")
        let exhausted = await budget.available
        XCTAssertEqual(exhausted, 0, "an unbounded recursion drains the budget to zero")
        XCTAssertEqual(results.count, delegate.fanOut)
    }
}

/// A delegate whose every node unconditionally fans out — the only thing that stops it is the budget.
private struct RecursiveDelegate: Sendable {
    let counter: SpawnCounter
    let fanOut: Int

    @Sendable
    func run(_ task: Int, _ budget: SpawnBudget) async throws -> Int {
        await counter.increment()
        let children = try await DelegateDispatch.dispatch(
            Array(0..<fanOut),
            budget: budget,
            worker: run,
            exhausted: { _ in 0 }
        )
        return 1 + children.reduce(0, +)
    }
}

private actor SpawnCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
