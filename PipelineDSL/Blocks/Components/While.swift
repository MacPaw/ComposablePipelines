//
//  While.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Reactive loop: **one** lowered body per emission whenever `condition()` is true.
///
/// There is **no** hidden execution-state slot. Progress and termination belong in normal
/// `@State` (or other bindings) that your body updates; each committed write bumps epoch,
/// the host re-lowers the pipeline, and `condition()` is evaluated again on the client.
///
/// Wrap the body in a gated group so one iteration’s tasks are not interleaved with the rest
/// of the graph under parallel compilation (`sequential: false`, `gate: true`).
///
/// Bounded loops (e.g. max passes) should be expressed in `condition()` using visible counters.
/// The engine’s ``PipelineWalker/maxReexecutionDepth`` still caps total re-execution rounds.
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

    public var pipelineGraph: PipelineGraph {
        let ctx = GraphEmissionContext.current
        let snapshot = ctx?.readCount ?? 0

        let shouldEmit = condition()

        _ = ctx?.drainReadsSince(snapshot)

        guard shouldEmit else { return .empty }

        let bodyGraph = iterationBodyBuilder().pipelineGraph
        return .group(
            sequential: false, gate: true,
            bodyGraph
        )
    }
}
