//
//  While.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Reactive loop: emits a ``PipelineGraph/loop(_:)`` scope for one iteration body whenever
/// `condition()` is true (and `.empty` when it is false).
///
/// The engine runs the body as a re-executable scope: its commits are **batched** and flushed once
/// when the iteration finishes (so a mid-body commit doesn't tear the iteration apart via
/// re-execution), and its `@State` writes **re-fire every iteration** instead of being frozen into
/// reads. After each iteration's commits the host re-lowers the pipeline and `condition()` is
/// evaluated again — so a body that mutates state (a counter, a retry, an agent turn) advances
/// until the condition is false.
///
/// There is **no** hidden execution-state slot. Progress and termination belong in normal `@State`
/// (or other bindings) that your body updates. Bounded loops (e.g. max passes) should be expressed
/// in `condition()` using visible counters; ``PipelineWalker/maxReexecutionDepth`` still caps total
/// re-execution rounds as a backstop.
///
/// ## Output
///
/// `Output == Body.Output`. When `condition()` is initially `false`, the lowered graph is
/// `.empty`.
///
/// ## Example
///
/// ```swift
/// @State var done = false
///
/// var body: some Pipeline {
///     While(condition: { !done }) {
///         $done.set { StepThatSetsDone() }
///     }
/// }
/// ```
public struct While<Body: Pipeline>: LeafPipeline {
    public typealias Output = Body.Output

    private let condition: @Sendable () -> Bool
    private let iterationBodyBuilder: @Sendable () -> Body

    public init(
        condition: @Sendable @escaping () -> Bool,
        @PipelineBuilder body: @Sendable @escaping () -> Body
    ) {
        self.condition = condition
        self.iterationBodyBuilder = body
    }

    /// Autoclosure spelling — the condition expression is re-evaluated on every emission,
    /// exactly like the closure form:
    ///
    /// ```swift
    /// While(!done) {
    ///     $done.set { StepThatSetsDone() }
    /// }
    /// ```
    public init(
        _ condition: @autoclosure @Sendable @escaping () -> Bool,
        @PipelineBuilder body: @Sendable @escaping () -> Body
    ) {
        self.init(condition: condition, body: body)
    }

    public var pipelineGraph: PipelineGraph {
        let ctx = GraphEmissionContext.current
        let snapshot = ctx?.readCount ?? 0

        let shouldEmit = condition()

        _ = ctx?.drainReadsSince(snapshot)

        guard shouldEmit else { return .empty }

        // Lower the body with the loop-body flag set so its `@State` writes are exempt from the
        // freeze-to-get guard and re-run each iteration. Emitting `.loop` (not `.group`) tells the
        // engine to run the body as a reactive scope: commits batched + flushed per iteration, and
        // its tasks kept out of the prefix-skip cursor.
        let bodyGraph = ExecutionContext.$isLoweringLoopBody.withValue(true) {
            iterationBodyBuilder().pipelineGraph
        }
        return .loop(bodyGraph)
    }
}
