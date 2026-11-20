//
//  _ConditionalPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Type produced by `buildEither(first:)` / `buildEither(second:)` inside `@PipelineBuilder`.
///
/// Unlike the dynamic `If` node, native `if`/`switch` branching is resolved at graph-construction
/// time — only the taken branch appears in the AST.
///
/// `controlFlowReads` carries `stateGet` nodes drained from ``GraphEmissionContext``
/// at the point where Swift evaluated the branch condition. These create explicit
/// RAW dependencies in the compiler so that the corresponding `stateSet` must
/// complete before the branch content executes.
public struct _ConditionalPipeline<First: Pipeline, Second: Pipeline>: Pipeline, PipelineStructuralNode {
    public typealias Output = First.Output
    public typealias Body = Never

    enum Branch {
        case first(First)
        case second(Second)
    }

    let branch: Branch
    let controlFlowReads: [PipelineGraph]

    public var body: Never {
        fatalError("_ConditionalPipeline is a structural node")
    }
}

extension _ConditionalPipeline: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph {
        let branchGraph: PipelineGraph
        switch branch {
        case let .first(pipeline):  branchGraph = pipeline.pipelineGraph
        case let .second(pipeline): branchGraph = pipeline.pipelineGraph
        }
        guard !controlFlowReads.isEmpty else { return branchGraph }
        let reads: PipelineGraph = controlFlowReads.count == 1 ? controlFlowReads[0] : .sequence(controlFlowReads)
        return .sequence([.group(sequential: true, gate: true, reads), branchGraph])
    }
}

