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
package enum TelemetryContext {
    /// The current pipeline run's id, used as the OTLP `traceId` for all of its spans.
    @TaskLocal package static var runID: UUID?

    /// The `pipeline.run` root span's id, so model spans nest under it as children.
    @TaskLocal package static var rootSpanID: String?

    /// The host-provided observer for the current run, bound in `PipelineWalker.run`. Read at
    /// emission sites so neutral metrics reach the host without a telemetry-backend dependency.
    @TaskLocal package static var observer: (any PipelineRunObserver)?
}
