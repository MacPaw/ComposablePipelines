//
//  TaskExecutionStatus.swift
//  elix-toolchain
//
//  Created by Oleksandr Frankiv on 21.04.2026.
//

import Foundation

/// The execution status of a single task node inside the pipeline graph.
/// Carried by `ExecutionEvent` step cases and available for state reconstruction.
public enum TaskExecutionStatus: Sendable, Equatable {
    /// The task is actively running.
    case inProgress
    /// The task finished successfully.
    case completed
    /// The task threw an error.
    case failed
    /// The task was served from the memo cache without re-executing,
    /// or was inside a branch that was not taken.
    case skipped
}
