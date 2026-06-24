import PipelineAST

/// Builder empty block (`buildBlock()`), SwiftUI ``EmptyView`` analogue.
public struct EmptyPipeline: Pipeline {
    public typealias Output = Never
    public typealias Body = Never

    public init() {}

    public var body: Never {
        fatalError("EmptyPipeline has no body")
    }
}

extension EmptyPipeline: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph { .empty }
}
