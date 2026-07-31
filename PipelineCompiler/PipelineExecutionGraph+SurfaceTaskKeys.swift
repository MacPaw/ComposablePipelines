//
//  PipelineExecutionGraph+SurfaceTaskKeys.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

extension PipelineExecutionGraph {

    // MARK: - Key-aligned prefix count

    /// Returns the number of leading surface tasks in `next` whose identity key matches
    /// the corresponding executed task in `previous`, stopping at the first mismatch.
    ///
    /// Using stable slot UUID keys (rather than a raw ordinal) prevents overshoot when
    /// a branch re-lowering changes the number of surface tasks before a shared suffix:
    ///
    ///   Previous (TRUE branch active):   memoryStore | slot:X | model   (3 tasks)
    ///   Next     (FALSE branch active):  slot:X      | model            (2 tasks)
    ///
    /// A positional skip of 3 would overshoot past `slot:X` and `model` in `next`.
    /// Key alignment stops at position 0 (memoryStore ≠ slot:X), so `slot:X` runs.
    ///
    /// - Parameters:
    ///   - previous: The graph that just finished executing.
    ///   - consumed: How many surface ordinals were walked in `previous`.
    ///   - next: The freshly recompiled graph.
    /// - Returns: The safe skip count to apply to `next`.
    public static func alignedPrefixCount(
        previous: PipelineExecutionGraph,
        consumed: Int,
        next: PipelineExecutionGraph
    ) -> Int {
        let previousOps = previous.surfaceOperations()
        let nextOps = next.surfaceOperations()
        let executed = min(consumed, previousOps.count)
        var count = 0
        while count < executed,
              count < nextOps.count,
              surfaceKey(for: previousOps[count]) == surfaceKey(for: nextOps[count]) {
            count += 1
        }
        return count
    }

    // MARK: - Surface operations

    /// Returns operations in branch-major walk order, matching ``surfaceTaskCount()``.
    /// Loop bodies return `[]` — their tasks live outside the prefix-skip ordinal space.
    func surfaceOperations() -> [Operation] {
        switch self {
        case .empty:
            return []
        case .task(let t):
            return [t.operation]
        case .returnWith(let inner):
            return inner.surfaceOperations()
        case .sequential(let steps):
            return steps.flatMap { $0.surfaceOperations() }
        case .parallel(let branches):
            return branches.flatMap { $0.surfaceOperations() }
        case .loopScope:
            return []
        }
    }

    // MARK: - Stable key per operation

    /// A stable string key that identifies an operation's kind and slot identity across
    /// re-executions. Slot operations use their UUID (stable across recompilation);
    /// everything else uses a type tag that stops alignment at the first kind mismatch.
    static func surfaceKey(for operation: Operation) -> String {
        switch operation {
        case .stateGet(let slotID, _, _, _):
            return "slot:\(slotID)"
        case .stateSet(let slotID, _, _, _, _):
            return "slot:\(slotID)"
        case .router:
            return "router"
        case .dagPlan:
            return "dagPlan"
        case .relevanceRank:
            return "relevanceRank"
        case .model(let config, _):
            return "model:\(config.outputTypeName):\(config.traits.rawValue)"
        case .modelInput(let config, _, _):
            return "modelInput:\(config.outputTypeName):\(config.traits.rawValue)"
        case .summarize(let slotID, _, _):
            return "summarize:\(slotID)"
        case .clientAction(let taskID, _):
            return "clientAction:\(taskID)"
        case .contextProvide(let providerID, _):
            return "contextProvide:\(providerID)"
        case .memoryQuery:
            return "memoryQuery"
        case .memoryStore(_, let mode):
            return "memoryStore:\(mode.rawValue)"
        case .constant(let valueTypeName, let json):
            return "const:\(valueTypeName):\(json)"
        }
    }
}
