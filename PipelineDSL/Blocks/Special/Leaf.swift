//
//  Leaf.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Marker body for leaf-shaped pipeline nodes that carry configuration elsewhere.
public struct Leaf<O>: Pipeline {
    public typealias Body = Never
    public typealias Output = O

    public init() {}

    public var body: Never {
        fatalError("Leaf pipeline has no body")
    }
}

extension Leaf: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph { .empty }
}
