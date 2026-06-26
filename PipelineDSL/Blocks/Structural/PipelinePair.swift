//
//  PipelinePair.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Left-associated pairing produced by multi-statement `body` blocks (`A` then `B` then `C` →
/// `PipelinePair<PipelinePair<A, B>, C>`).
///
/// The composed ``Output`` is ``Second.Output``; intermediate values are expected to flow through shared
/// ``State`` / runtime context, not through generic ``Input``/``Output`` wiring.
public struct PipelinePair<First: Pipeline, Second: Pipeline>: Pipeline, PipelineStructuralNode {
    public typealias Output = Second.Output
    public typealias Body = Never

    public var first: First
    public var second: Second

    public init(first: First, second: Second) {
        self.first = first
        self.second = second
    }

    public var body: Never {
        fatalError("PipelinePair is a structural node; use stored properties first/second")
    }
}

extension PipelinePair: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph {
        .sequence([first.pipelineGraph, second.pipelineGraph])
    }
}

extension PipelinePair: BooleanPipeline where Second.Output == Bool {}
