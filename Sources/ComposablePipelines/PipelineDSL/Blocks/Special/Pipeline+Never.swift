import PipelineAST

extension Never: Pipeline {
    public typealias Output = Never
    public typealias Body = Never

    public var body: Never {
        fatalError("Never cannot be instantiated as Pipeline")
    }
}

extension Never: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph {
        fatalError("Never cannot be lowered to a pipeline graph")
    }
}
