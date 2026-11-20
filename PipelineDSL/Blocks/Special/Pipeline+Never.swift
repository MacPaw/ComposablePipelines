//
//  Pipeline+Never.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

extension Never: Pipeline {
    public typealias Output = Never
    public typealias Body = Never

    public var body: Never {
        fatalError("Never cannot be instantiated as Pipeline")
    }
}

extension Never: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph {
        fatalError("Never cannot be lowered to a pipeline graph")
    }
}
