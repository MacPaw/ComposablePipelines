//
//  ExecutionEvent.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

// MARK: - ExecutionEvent

/// Fine-grained event emitted by the execution engine during a pipeline run.
///
/// Observers receive individual step lifecycle and state-change notifications instead
/// of coarse full-state snapshots, matching the `ComposablePipelines` walker model.
public enum ExecutionEvent: Sendable {
    /// A task has started executing.
    case stepStarted(StepInfo)
    /// A task finished successfully.
    case stepCompleted(StepInfo, resultPreview: String, duration: UInt64)
    /// A task was served from the memo cache and did not re-execute.
    case stepSkipped(StepInfo)
    /// A slot was written by a `stateSet` operation.
    case stateUpdated(StateUpdate)
    /// A `.parallel` group began; `count` is the number of concurrent branches.
    case parallelGroupStarted(count: Int)
    /// A `.parallel` group finished; `executed` is how many branches ran (vs cache-skipped).
    case parallelGroupCompleted(count: Int, executed: Int)
    /// A task threw an error. The error propagates after this event is emitted.
    case stepFailed(StepInfo, error: any Error, duration: UInt64)
    /// The re-execution loop started a new iteration (future: re-execution support).
    case reexecutionStarted(depth: Int)
    /// Resource loading progress for the current pipeline run iteration.
    case resourceProgressUpdated(ExecutionProgressUpdate)
    /// A memory store operation was launched. Async stores emit this before returning.
    case memoryStoreStarted(entryCount: Int, mode: MemoryStoreMode)
    /// A memory store operation finished after it was launched.
    case memoryStoreCompleted(entryCount: Int, mode: MemoryStoreMode, errorDescription: String?)
    /// The top-level `run(...)` call completed successfully.
    case executionCompleted
    /// Incremental model output text produced during a `.model` step (token streaming).
    case modelOutputDelta(taskID: UUID, text: String)
}

public struct ExecutionProgressUpdate: Sendable {
    public let runID: UUID
    public let iteration: Int
    public let fraction: Double
}

// MARK: - StepInfo

/// Label of a single task node, attached to step lifecycle events.
public struct StepInfo: Sendable {
    public let taskID: UUID
    /// Short canonical operation name — `"stateSet"`, `"model"`, `"guardrail"`, etc.
    /// Use for category-level matching (e.g., trace assertions).
    public let operationLabel: String
    /// Human-readable label including slot binding / model output type — `"$severity.set"`,
    /// `"guardrail([.geopolitics, .illegal])"`, `"model → String"`.
    public let prettyLabel: String
    /// Slot UUID for `stateGet` / `stateSet` operations; `nil` for everything else.
    /// Lets observers correlate a step with the slot it touched without re-walking
    /// the compiled graph (e.g., trace projectors looking up the cached value of a
    /// prefix-skipped `stateGet`).
    public let slotID: UUID?
}

// MARK: - ExecutionEvent helpers

extension ExecutionEvent {

    /// The `StepInfo` embedded in any step lifecycle event, or `nil` for non-step events.
    public var stepInfo: StepInfo? {
        switch self {
        case .stepStarted(let i),
             .stepCompleted(let i, _, _),
             .stepSkipped(let i),
             .stepFailed(let i, _, _): return i
        default: return nil
        }
    }

    /// Maps each step lifecycle event to a `TaskExecutionStatus` for state reconstruction.
    ///
    /// Observers can maintain a `[UUID: TaskExecutionStatus]` dictionary by applying this
    /// property as events arrive, building a live snapshot of every task's current state.
    public var taskStatus: TaskExecutionStatus? {
        switch self {
        case .stepStarted:   return .inProgress
        case .stepCompleted: return .completed
        case .stepSkipped:   return .skipped
        case .stepFailed:    return .failed
        default:             return nil
        }
    }
}
