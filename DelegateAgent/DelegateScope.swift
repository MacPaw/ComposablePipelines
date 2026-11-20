//
//  DelegateScope.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// The ambient context a subagent **inherits** from its parent — the `@Environment` analog of the
/// delegate. It flows *down* the tree: a subagent's identity (``DelegateRunID``) and the budget shape of the
/// delegate it belongs to.
///
/// The Phase 3.1 spike established that ambient context needs no new transport — it rides *down* by
/// being seeded into the child's isolated run (`initialSlots`), the same way the task value is. A
/// subagent that needs to know its own position (e.g. to tag its ``DelegateResult`` or to derive its own
/// children's ids) reads its `DelegateScope` from the seeded slot.
///
/// Two other ambient concerns flow down without riding here:
/// - **Budget** is carried by the `.delegate` leaf itself (`budgetTotal` / `leafReserve` → one shared
///   `SpawnBudget` per delegate level).
/// - **Cancellation** rides Swift structured concurrency: cancelling the delegate's task cancels the
///   child `TaskGroup`s, so no token needs threading through state.
///
/// - Author: Claude
public struct DelegateScope: Codable, Sendable, Hashable {
    /// This subagent's position in the delegate tree.
    public var runID: DelegateRunID
    /// The spawn cap of the delegate level this subagent belongs to (for reporting / derived budgets).
    public var budgetTotal: Int
    /// The leaf reserve of that budget.
    public var budgetLeafReserve: Int

    public init(runID: DelegateRunID, budgetTotal: Int, budgetLeafReserve: Int = 0) {
        self.runID = runID
        self.budgetTotal = budgetTotal
        self.budgetLeafReserve = budgetLeafReserve
    }

    /// The scope a child at `index` inherits from this one: same budget shape, id extended by the
    /// child's tree position.
    public func child(_ index: Int) -> DelegateScope {
        DelegateScope(runID: runID.child(index), budgetTotal: budgetTotal, budgetLeafReserve: budgetLeafReserve)
    }
}
