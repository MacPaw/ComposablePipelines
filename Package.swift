// swift-tools-version: 5.9
//
// ComposablePipelines — the open, runtime-agnostic stack for composing AI pipelines:
// a SwiftUI-like DSL, a Codable AST, a compiler, and an observable walker. Execution
// plugs in through the `Executor` seam.
//
// Copyright © 2026 MacPaw Inc. Licensed under the Apache License, Version 2.0 (see LICENSE).

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "ComposablePipelines",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Umbrella over the whole open stack: one `import ComposablePipelines` re-exports it all.
        .library(name: "ComposablePipelines", targets: ["ComposablePipelines"]),
        .library(name: "PipelineAST", targets: ["PipelineAST"]),
        .library(name: "PipelineDSL", targets: ["PipelineDSL"]),
        .library(name: "PipelineCompiler", targets: ["PipelineCompiler"]),
        .library(name: "ExecutionEngine", targets: ["ExecutionEngine"]),

        // Runnable reference pipelines — read them, copy them, learn the DSL. Built (and
        // execution-tested) as part of the package so they never drift from the API.
        .library(name: "Examples", targets: ["Examples"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax", from: "600.0.0"),
    ],
    targets: [
        // Codable wire-format AST. Foundation-only.
        .target(name: "PipelineAST", path: "PipelineAST"),

        // Preview macro backing `@PipelinePreview`.
        .macro(
            name: "PipelinePreviewMacro",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            path: "PipelinePreviewMacro"
        ),

        // Authoring DSL. Re-exports PipelineAST.
        .target(
            name: "PipelineDSL",
            dependencies: [
                "PipelineAST",
                "PipelinePreviewMacro",
            ],
            path: "PipelineDSL"
        ),

        // AST → optimized execution graph (+ the PipelineLog seam).
        .target(
            name: "PipelineCompiler",
            dependencies: ["PipelineAST"],
            path: "PipelineCompiler"
        ),

        // The observable PipelineWalker + the Executor seam + MockExecutor.
        .target(
            name: "ExecutionEngine",
            dependencies: ["PipelineAST", "PipelineCompiler"],
            path: "ExecutionEngine"
        ),

        // Umbrella — `@_exported import`s the whole open stack. No code of its own.
        .target(
            name: "ComposablePipelines",
            dependencies: ["PipelineAST", "PipelineDSL", "PipelineCompiler", "ExecutionEngine"],
            path: "ComposablePipelines"
        ),

        // Reference pipelines. Authoring-only — depends on PipelineDSL, nothing else.
        .target(
            name: "Examples",
            dependencies: ["PipelineDSL"],
            path: "Examples"
        ),

        // Foundation-only OpenAI-compatible Executor (non-product; demo + tests link it).
        .target(
            name: "OpenAIExecutor",
            dependencies: ["ExecutionEngine", "PipelineAST"],
            path: "OpenAIExecutor"
        ),

        // Runnable end-to-end demo: compile → walk → real OpenAI-compatible model.
        .executableTarget(
            name: "cp-demo",
            dependencies: ["OpenAIExecutor", "ComposablePipelines"],
            path: "Demo"
        ),

        // opencode-"Build"-style coding agent: confined tools + a tool-calling agent loop.
        .target(
            name: "CodingAgent",
            dependencies: ["ComposablePipelines"],
            path: "CodingAgent"
        ),

        // Runnable coding agent against a real OpenAI-compatible model.
        .executableTarget(
            name: "cp-agent",
            dependencies: ["CodingAgent", "OpenAIExecutor", "ComposablePipelines"],
            path: "CodingAgentDemo"
        ),

        // MARK: - Tests
        .testTarget(
            name: "PipelineDSLTests",
            dependencies: ["PipelineDSL", "PipelineAST"],
            path: "Tests/PipelineDSLTests"
        ),
        .testTarget(
            name: "PipelineCompilerTests",
            dependencies: ["PipelineCompiler", "PipelineAST"],
            path: "Tests/PipelineCompilerTests"
        ),
        .testTarget(
            name: "ExecutionEngineTests",
            dependencies: ["ExecutionEngine", "PipelineCompiler", "PipelineDSL", "PipelineAST", "Examples"],
            path: "Tests/ExecutionEngineTests"
        ),
        .testTarget(
            name: "OpenAIExecutorTests",
            dependencies: ["OpenAIExecutor", "ExecutionEngine", "PipelineAST"],
            path: "Tests/OpenAIExecutorTests"
        ),
        .testTarget(
            name: "CodingAgentTests",
            dependencies: ["CodingAgent", "ComposablePipelines", "ExecutionEngine", "PipelineAST"],
            path: "Tests/CodingAgentTests"
        ),
    ]
)
