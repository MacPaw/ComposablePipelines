//
//  PipelineRunObserver.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Observation seam for the **run-level** span of a pipeline.
///
/// The walker reports the root `pipeline.run` span here; a host plugs in an implementation (e.g. an
/// OTLP exporter) without the walker depending on a telemetry backend. The observer's *presence*
/// also signals that telemetry is enabled — model-level spans are emitted by the host's executor
/// directly (it owns the metrics), so this protocol carries no resource types and keeps the walker
/// free of any host resource/telemetry dependencies.
public protocol PipelineRunObserver: Sendable {

    /// The root `pipeline.run` finished (or failed with `error`).
    func pipelineRun(runID: UUID, spanID: String, start: Date, end: Date, error: Error?)
}

/// A 16-hex-character span id (OTLP `spanId` width), generated without a telemetry backend.
package func makePipelineSpanID() -> String {
    String(format: "%016llx", UInt64.random(in: .min ... .max))
}
