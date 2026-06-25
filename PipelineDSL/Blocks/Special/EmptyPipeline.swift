//
//  EmptyPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Builder empty block (`buildBlock()`), SwiftUI ``EmptyView`` analogue.
public struct EmptyPipeline: Pipeline {
    public typealias Output = Never
    public typealias Body = Never

    public init() {}

    public var body: Never {
        fatalError("EmptyPipeline has no body")
    }
}

extension EmptyPipeline: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph { .empty }
}
