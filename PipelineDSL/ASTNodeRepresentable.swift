//
//  ASTNodeRepresentable.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Graph node this pipeline contributes when lowered to ``PipelineGraph``.
public protocol ASTNodeRepresentable {
    /// Control-flow shape for this node (and structurally nested pipelines, if any).
    var pipelineGraph: PipelineGraph { get }
}
