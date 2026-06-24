//
//  ComposablePipelines.swift
//  ComposablePipelines
//
//  Umbrella module for the open Composable Pipelines stack. A single
//  `import ComposablePipelines` re-exports the whole author → compile → walk path:
//  the authoring DSL, the Codable AST, the compiler, and the observable walker.
//
//  This target carries no code of its own — it only re-exports its dependencies.
//

@_exported import PipelineAST
@_exported import PipelineDSL
@_exported import PipelineCompiler
@_exported import ExecutionEngine
