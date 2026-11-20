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

    /// How the loop condition is evaluated: a closure re-checked by **re-lowering** (`.loop`), or a
    /// `Bool` **slot** evaluated **in-graph** by the walker (`.whileLoop`). The slot form needs no
    /// re-lowering, so it works inside a delegate's static walk (where there is no `graphProvider`).
    private enum Condition {
        case closure(@Sendable () -> Bool)
        case slot(Binding<Bool>)
    }

    private let condition: Condition
    private let iterationBodyBuilder: @Sendable () -> Body

    public init(
        condition: @Sendable @escaping () -> Bool,
        @PipelineBuilder body: @Sendable @escaping () -> Body
    ) {
        self.condition = .closure(condition)
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

    /// **Slot-driven** spelling: loop while the `Bool` in `condition` is true, evaluated **in-graph**
    /// by the walker (no re-lowering). The body must update that slot to terminate. Unlike the
    /// closure form, this works inside a delegate's static walk — use it for reactive loops (tool loops,
    /// retries) in a self-cloning agent.
    ///
    /// ```swift
    /// While($keepGoing) {
    ///     $keepGoing.set { StepThatMayFinish() }   // sets the slot false to stop
    /// }
    /// ```
    public init(
        _ condition: Binding<Bool>,
        @PipelineBuilder body: @Sendable @escaping () -> Body
    ) {
        self.condition = .slot(condition)
        self.iterationBodyBuilder = body
    }

    public var pipelineGraph: PipelineGraph {
        // Lower the body with the loop-body flag set so its `@State` writes are exempt from the
        // freeze-to-get guard and re-run each iteration.
        func bodyGraph() -> PipelineGraph {
            ExecutionContext.$isLoweringLoopBody.withValue(true) {
                iterationBodyBuilder().pipelineGraph
            }
        }

        switch condition {
        case let .slot(binding):
            // In-graph: the walker re-reads the slot each iteration. Always emit the loop node.
            return .whileLoop(conditionSlotID: binding.id, body: bodyGraph())
        case let .closure(check):
            let ctx = GraphEmissionContext.current
            let snapshot = ctx?.readCount ?? 0
            let shouldEmit = check()
            _ = ctx?.drainReadsSince(snapshot)
            guard shouldEmit else { return .empty }
            // Emitting `.loop` (not `.group`) tells the engine to run the body as a reactive scope:
            // commits batched + flushed per iteration, tasks kept out of the prefix-skip cursor.
            return .loop(bodyGraph())
        }
    }
}
