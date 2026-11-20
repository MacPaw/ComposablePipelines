//
//  DelegateKillLosersTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import ExecutionEngine
import DelegateAgent

/// Phase 5.2 — once a completion policy is satisfied, the losing subagents (and their whole subtrees)
/// are cancelled, freeing their slots immediately. Proven structurally: a fast winner triggers the
/// policy while the losers are deep in long-running subtrees; the run returns *fast* (it does not
/// wait on the losers), and neither the losers nor their grandchildren ever complete.
final class DelegateKillLosersTests: XCTestCase {

    private actor Ledger {
        var loserCompletions = 0
        var grandchildCompletions = 0
        func recordLoser() { loserCompletions += 1 }
        func recordGrandchild() { grandchildCompletions += 1 }
    }

    func testWinnerCancelsLosingSubtrees() async throws {
        let ledger = Ledger()
        let budget = SpawnBudget(total: 100, leafReserve: 0)

        let winners = try await DelegateDispatch.dispatchUntil(
            Array(0..<5),
            budget: budget,
            isSatisfied: { (results: [String]) in results.contains("winner") },
            worker: { index, childBudget in
                if index == 0 {
                    return "winner"   // fast — satisfies the policy immediately
                }
                // Loser: spawn a grandchild subtree that would take a long time if not cancelled.
                _ = try await DelegateDispatch.dispatch(
                    [0, 1],
                    budget: childBudget,
                    worker: { _, _ in
                        try await Task.sleep(for: .seconds(60))
                        await ledger.recordGrandchild()
                        return "grandchild"
                    },
                    exhausted: { _ in "refused" }
                )
                await ledger.recordLoser()
                return "loser"
            }
        )

        XCTAssertEqual(winners, ["winner"], "the fast winner ends the delegate")
        let loserCompletions = await ledger.loserCompletions
        let grandchildCompletions = await ledger.grandchildCompletions
        XCTAssertEqual(loserCompletions, 0, "losing workers were cancelled before completing")
        XCTAssertEqual(grandchildCompletions, 0, "cancellation cascaded into the losers' subtrees")
    }
}
