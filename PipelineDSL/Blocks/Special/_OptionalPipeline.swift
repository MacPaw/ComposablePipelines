//
//  _OptionalPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Type produced by `buildOptional(_:)` inside `@PipelineBuilder`.
///
/// Wraps an `if`-without-`else`: the branch is resolved at graph-construction time.
/// When the condition is false the pipeline contributes `.empty` to the AST.
///
/// `controlFlowReads` carries `stateGet` nodes drained from ``GraphEmissionContext``
/// so that the corresponding `stateSet` must complete before the branch content.
public struct _OptionalPipeline<Wrapped: Pipeline>: Pipeline, PipelineStructuralNode {
    public typealias Output = Wrapped.Output
    public typealias Body = Never

    let wrapped: Wrapped?
    let controlFlowReads: [PipelineGraph]

    public var body: Never {
        fatalError("_OptionalPipeline is a structural node")
    }
}

extension _OptionalPipeline: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph {
        let inner = wrapped?.pipelineGraph
        if controlFlowReads.isEmpty {
            return inner ?? .empty
        }
        let reads: PipelineGraph = controlFlowReads.count == 1 ? controlFlowReads[0] : .sequence(controlFlowReads)
        let gatedReads = PipelineGraph.group(sequential: true, gate: true, reads)
        if let inner {
            return .sequence([gatedReads, inner])
        }
        return gatedReads
    }
}
