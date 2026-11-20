//
//  TelemetryContext.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Ambient telemetry context for the current pipeline run.
///
/// Set once in `PipelineWalker.run` and read at model-operation emission sites, so the
/// `runID` (the OTLP trace id) reaches them without threading it through every operation
/// signature. Mirrors the `@TaskLocal` propagation used by `ExecutionProgressReporter`.
@_spi(Internals) public enum TelemetryContext {
    /// The current pipeline run's id, used as the OTLP `traceId` for all of its spans.
    @TaskLocal @_spi(Internals) public static var runID: UUID?

    /// The `pipeline.run` root span's id, so model spans nest under it as children.
    @TaskLocal @_spi(Internals) public static var rootSpanID: String?

    /// The host-provided observer for the current run, bound in `PipelineWalker.run`. Read at
    /// emission sites so neutral metrics reach the host without a telemetry-backend dependency.
    @TaskLocal @_spi(Internals) public static var observer: (any PipelineRunObserver)?

    /// The ``DelegateRunID`` path of the walker running the current step, empty at the top.
    ///
    /// A task-local rather than a parameter because the alternative is threading the path through
    /// `Executor.runModel` — a public protocol in the mirrored package, which every external conformer
    /// would have to re-declare to report a figure most of them do not collect. The path is ambient to a
    /// subagent's whole execution, which is what a task-local is for.
    ///
    /// - Author: Claude
    @TaskLocal @_spi(Internals) public static var delegatePath: [Int] = []
}
