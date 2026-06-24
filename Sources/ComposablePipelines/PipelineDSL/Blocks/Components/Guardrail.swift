import PipelineAST

/// Coarse policy gate for a pipeline.
///
/// This abstraction should be revisited as guardrail workflows mature. A
/// pipeline may express the same behavior from smaller atomic parts: a model
/// for classification, a model for response generation, and an explicit
/// `return` for early exit when the classification fails.
public struct Guardrail: BooleanLeaf {
    public typealias Output = Bool

    public let rules: [GuardrailRule]
    public let gated: Bool

    public init(rules: [GuardrailRule], gated: Bool = true) {
        self.rules = rules
        self.gated = gated
    }
}

extension Guardrail {
    public var pipelineGraph: PipelineGraph {
        let leaf: PipelineGraph = .leaf(.guardrail(rules: rules))
        return gated ? .group(sequential: true, gate: true, leaf) : leaf
    }
}
