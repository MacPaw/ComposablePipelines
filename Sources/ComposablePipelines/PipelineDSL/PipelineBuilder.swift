@resultBuilder
public enum PipelineBuilder {
    public static func buildBlock() -> EmptyPipeline {
        EmptyPipeline()
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
