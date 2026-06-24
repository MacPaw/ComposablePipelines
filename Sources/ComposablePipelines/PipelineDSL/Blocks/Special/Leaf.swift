import PipelineAST

/// Marker body for leaf-shaped pipeline nodes that carry configuration elsewhere.
public struct Leaf<O>: Pipeline {
    public typealias Body = Never
    public typealias Output = O

    public init() {}

    public var body: Never {
        fatalError("Leaf pipeline has no body")
    }
}

extension Leaf: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph { .empty }
}
