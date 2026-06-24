//
//  ExecutionProgressReporter.swift
//  elix-toolchain
//

import Foundation

/// Open progress reporter the walker binds for the duration of a pass.
///
/// The walker turns reported fractions into `resourceProgressUpdated` execution events. A backend
/// that loads models reports progress through `current`; the proprietary executor bridges its own
/// resource-load progress into this reporter. This is the open replacement for the walker's former
/// dependency on `ElixResources.ResourceProgress` — progress is observation, which stays open.
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
