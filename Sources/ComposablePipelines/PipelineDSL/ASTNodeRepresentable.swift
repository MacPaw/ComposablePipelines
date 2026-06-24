import PipelineAST

/// Graph node this pipeline contributes when lowered to ``PipelineGraph``.
public protocol ASTNodeRepresentable {
    /// Control-flow shape for this node (and structurally nested pipelines, if any).
    var pipelineGraph: PipelineGraph { get }
}
