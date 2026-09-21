//
//  StateSetOperation.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Executes a `.stateSet` operation: writes a pre-resolved value to a named
/// slot in the `ExecutionContext` and records a `StateUpdate` for observers.
/// Commit writes batch across `.parallel` and may invoke `graphProvider`; draft
/// writes notify observers immediately without `graphProvider`.
///
/// The calling `GraphWalker` is responsible for walking the value subgraph
/// before invoking `execute`; this struct only handles persistence and events.
struct StateSetOperation: Sendable {

    let context: ExecutionContext

    func execute(
        slotID: UUID,
        valueTypeName: String,
        debugLabel: String?,
        value: ExecutionValue,
        kind: StateWriteKind = .commit
    ) async throws -> ExecutionValue {
        let previousValue = await context.getSlot(slotID)
        await context.setSlot(slotID, value: value)
        // Skip the state update event when the value has not changed.
        // A no-op write must not notify observers or trigger graphProvider re-evaluation.
        guard previousValue != value else { return value }
        await context.recordStateWrite(
            slotID: slotID,
            valueTypeName: valueTypeName,
            debugLabel: debugLabel,
            previousValue: previousValue,
            value: value,
            kind: kind
        )
        return value
    }
}
