//
//  PipelineBuilder.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

@resultBuilder
public enum PipelineBuilder {
    public static func buildBlock() -> EmptyPipeline {
        EmptyPipeline()
    }

    // MARK: - Expressions

    public static func buildExpression<T: Pipeline>(_ expression: T) -> T {
        expression
    }

    /// A bare `$binding` statement is a graph-level slot read — sugar for `$binding.get()`.
    /// Most useful as the last line of a body, where it makes the slot the pipeline's output.
    public static func buildExpression<Value>(_ binding: Binding<Value>) -> Binding<Value>.GetValue {
        binding.get()
    }

    public static func buildPartialBlock<First: Pipeline>(first: First) -> First {
        first
    }

    public static func buildPartialBlock<Accumulated: Pipeline, Next: Pipeline>(
        accumulated: Accumulated,
        next: Next
    ) -> PipelinePair<Accumulated, Next> {
        PipelinePair(first: accumulated, second: next)
    }

    // MARK: - Native if/else & switch

    public static func buildEither<First: Pipeline, Second: Pipeline>(
        first component: First
    ) -> _ConditionalPipeline<First, Second> {
        _ConditionalPipeline(
            branch: .first(component),
            controlFlowReads: GraphEmissionContext.current?.drainReads() ?? []
        )
    }

    public static func buildEither<First: Pipeline, Second: Pipeline>(
        second component: Second
    ) -> _ConditionalPipeline<First, Second> {
        _ConditionalPipeline(
            branch: .second(component),
            controlFlowReads: GraphEmissionContext.current?.drainReads() ?? []
        )
    }

    // MARK: - Native if (no else)

    public static func buildOptional<T: Pipeline>(_ component: T?) -> _OptionalPipeline<T> {
        _OptionalPipeline(
            wrapped: component,
            controlFlowReads: GraphEmissionContext.current?.drainReads() ?? []
        )
    }

    // MARK: - #available / @available

    public static func buildLimitedAvailability<T: Pipeline>(_ component: T) -> T {
        component
    }
}
