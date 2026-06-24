import Foundation

/// Policy rule identifiers stored on the pipeline AST (``PipelineGraphLeaf/guardrail(rules:)``); runners decode this without the DSL.
public enum GuardrailRule: String, Codable, Sendable, Hashable {
    case politics
    case pii
}
