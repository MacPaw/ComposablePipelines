//
//  When.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// **Slot-driven** conditional, evaluated **in-graph** by the walker (no re-lowering): run `then` when
/// the `Bool` in `condition` is true, otherwise `otherwise`.
///
/// This is the in-graph counterpart of a value-dependent `if` in the DSL. The DSL's `if` is resolved by
/// **re-lowering** the pipeline (which needs a `graphProvider`), so it can't run inside a delegate's static
/// walk; `When` branches from a committed slot the walker reads directly, so it works everywhere — use
/// it for value-dependent branching inside a self-cloning agent. Put the decision in a `Bool` slot
/// first (`$isX.set { Run(...) { … } }`), then branch on it.
///
/// ```swift
/// $split.set { Run(input: $decision) { $0.isSplit } }
/// When($split) {
///     $out.set { … fan out … }
/// } else: {
///     $out.set { … handle directly … }
/// }
/// ```
///
/// - Author: Claude
public struct When<Then: Pipeline, Else: Pipeline>: LeafPipeline {
    /// The static output type reflects only the **then** branch. When the `else` branch has a different
    /// `Output`, or when the else-less form runs nothing, the value the walker produces may not match this
    /// type — so drive data through slots (`$out.set { When(...) }`), the intended reactive pattern, rather
    /// than consuming `When`'s output directly.
    public typealias Output = Then.Output

    private let condition: Binding<Bool>
    private let thenBuilder: @Sendable () -> Then
    private let elseBuilder: @Sendable () -> Else

    public init(
        _ condition: Binding<Bool>,
        @PipelineBuilder then: @Sendable @escaping () -> Then,
        @PipelineBuilder `else` elseBuilder: @Sendable @escaping () -> Else
    ) {
        self.condition = condition
        self.thenBuilder = then
        self.elseBuilder = elseBuilder
    }

    public var pipelineGraph: PipelineGraph {
        .branch(
            conditionSlotID: condition.id,
            then: thenBuilder().pipelineGraph,
            otherwise: elseBuilder().pipelineGraph
        )
    }
}

public extension When where Else == EmptyPipeline {
    /// Else-less form: run `then` when the condition slot is true, otherwise nothing.
    init(
        _ condition: Binding<Bool>,
        @PipelineBuilder then: @Sendable @escaping () -> Then
    ) {
        self.init(condition, then: then, else: { EmptyPipeline() })
    }
}
