//
//  SpawnBudgetTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import ExecutionEngine
import DelegateAgent

/// Phase 1.1 — the spawn-budget accountant in isolation: grants are bounded, pools never go negative,
/// the leaf reserve is protected from descent, and concurrent reservers never over-grant.
final class SpawnBudgetTests: XCTestCase {

    func testReserveNeverExceedsRequestedOrAvailable() async {
        let budget = SpawnBudget(total: 10, leafReserve: 0)

        let first = await budget.reserve(4)
        XCTAssertEqual(first, 4)

        // Only 6 left in the descent pool; a request for 8 is clamped to 6.
        let second = await budget.reserve(8)
        XCTAssertEqual(second, 6)

        // Exhausted: further reservations grant nothing (refuse-at-zero).
        let third = await budget.reserve(1)
        XCTAssertEqual(third, 0)
        let remaining = await budget.available
        XCTAssertEqual(remaining, 0)
    }

    func testDescentNeverDrawsOnLeafReserve() async {
        let budget = SpawnBudget(total: 5, leafReserve: 2)

        // Descent pool is total - leafReserve = 3.
        let bulk = await budget.reserve(100)
        XCTAssertEqual(bulk, 3)
        let spill = await budget.reserve(1)
        XCTAssertEqual(spill, 0, "descent must not spill into the leaf reserve")

        // The 2 reserved leaf slots are still claimable.
        let leaf1 = await budget.tryAcquireLeafSlot()
        let leaf2 = await budget.tryAcquireLeafSlot()
        let leaf3 = await budget.tryAcquireLeafSlot()
        XCTAssertTrue(leaf1)
        XCTAssertTrue(leaf2)
        XCTAssertFalse(leaf3, "budget fully exhausted")
    }

    func testLeafSlotFallsBackToDescentPool() async {
        let budget = SpawnBudget(total: 3, leafReserve: 1)

        // 1 leaf-reserve slot + 2 descent-pool slots = 3 leaf acquisitions total.
        let a = await budget.tryAcquireLeafSlot()   // leaf reserve
        let b = await budget.tryAcquireLeafSlot()   // descent fallback
        let c = await budget.tryAcquireLeafSlot()   // descent fallback
        let d = await budget.tryAcquireLeafSlot()
        XCTAssertTrue(a)
        XCTAssertTrue(b)
        XCTAssertTrue(c)
        XCTAssertFalse(d)
    }

    func testReleaseReturnsUnspentSlackWithinCapacity() async {
        let budget = SpawnBudget(total: 6, leafReserve: 0)

        let reserved = await budget.reserve(6)
        XCTAssertEqual(reserved, 6)
        let afterReserve = await budget.available
        XCTAssertEqual(afterReserve, 0)

        // A subtree used only 2 of its 4 reserved units; release the 2 unspent.
        await budget.release(2)
        let afterRelease = await budget.available
        XCTAssertEqual(afterRelease, 2)
        let reReserved = await budget.reserve(2)
        XCTAssertEqual(reReserved, 2, "released slack is reusable by siblings")
    }

    func testReleaseCannotInflateCapacityAboveTotal() async {
        let budget = SpawnBudget(total: 4, leafReserve: 1)

        // Reserve the whole descent pool (3), leaving only the 1 leaf-reserve slot.
        let reserved = await budget.reserve(3)
        XCTAssertEqual(reserved, 3)

        // A buggy / double over-release must NOT push spendable capacity above the original cap.
        await budget.release(100)
        let available = await budget.available
        XCTAssertEqual(available, 4, "release is capped at total; it cannot inflate capacity")
        let regrant = await budget.reserve(100)
        XCTAssertEqual(regrant, 3, "at most total - leafReserve is grantable to descent")
    }

    func testConcurrentReserversNeverOverGrant() async {
        let total = 64
        let budget = SpawnBudget(total: total, leafReserve: 0)

        let grants = await withTaskGroup(of: Int.self) { group -> [Int] in
            for _ in 0..<128 {
                group.addTask { await budget.reserve(1) }
            }
            var all: [Int] = []
            for await g in group { all.append(g) }
            return all
        }

        XCTAssertEqual(grants.reduce(0, +), total, "sum of grants must equal the cap exactly")
        let leftover = await budget.available
        XCTAssertEqual(leftover, 0)
    }
}
