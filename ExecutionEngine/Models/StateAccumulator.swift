//
//  StateAccumulator.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Accumulates `StateUpdate` batches into a running snapshot of all slot values.
///
/// Designed for use inside `graphProvider` closures where the engine delivers only
/// the latest batch of updates per flush. `StateAccumulator` merges every batch so
/// callers always have access to the full, up-to-date slot state without manual
/// tracking.
///
/// ```swift
/// let accumulator = StateAccumulator()
/// let provider: ([StateUpdate]) -> PipelineExecutionGraph? = { updates in
///     accumulator.apply(updates)
///     // accumulator.snapshot now reflects all slot writes so far
///     return rebuildGraph(from: accumulator.snapshot)
/// }
/// ```
package final class StateAccumulator: @unchecked Sendable {

    /// The current accumulated snapshot: maps slot IDs to their most recent values.
    package private(set) var snapshot: [UUID: ExecutionValue] = [:]

    package init() {}

    /// Merges a batch of state updates into the snapshot.
    /// Each **committed** update overwrites the previous value for its slot; drafts are ignored
    /// so streaming previews do not perturb ``graphProvider`` rebuild snapshots.
    package func apply(_ updates: [StateUpdate]) {
        for update in updates where update.kind == .commit {
            snapshot[update.slotID] = update.value
        }
    }
}
