import PipelineAST

/// Re-export ``PipelineAST/JSONValue`` as the canonical `JSONValue` in this module,
/// shadowing any identically-named type from transitively-imported modules.
public typealias JSONValue = PipelineAST.JSONValue
