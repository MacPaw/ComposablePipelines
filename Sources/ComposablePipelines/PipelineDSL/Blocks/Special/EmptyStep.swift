import PipelineAST

/// Empty branch (e.g. an `If` `else:` arm that does nothing in the graph).
public struct EmptyStep<Output>: LeafPipeline {
    public typealias Output = Output

    public init() {}
}

extension EmptyStep {
    public var pipelineGraph: PipelineGraph { .empty }
}
