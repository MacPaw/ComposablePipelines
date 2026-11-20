//
//  ExecutionProgressReporter.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Open progress reporter the walker binds for the duration of a pass.
///
/// The walker turns reported fractions into `resourceProgressUpdated` execution events. A backend
/// that loads models reports progress through `current`; the host's executor bridges its own
/// resource-load progress into this reporter. This keeps progress reporting — which is observation
/// — open, without the walker depending on any host resource types.
public final class ExecutionProgressReporter: @unchecked Sendable {

    /// Ambient reporter for the current pass, bound by `PipelineWalker.run`.
    @TaskLocal public static var current: ExecutionProgressReporter?

    private let onUpdate: @Sendable (Double) -> Void

    public init(_ onUpdate: @escaping @Sendable (Double) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Report a model-load progress fraction in `[0, 1]`.
    public func report(_ fraction: Double) {
        onUpdate(fraction)
    }
}
