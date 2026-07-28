//
//  Router.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

public struct Router<Query: Pipeline>: LeafPipeline where Query.Output == String {
    public typealias Output = String

    public let query: Query
    public let tools: [ToolDescriptor]

    public init(tools: [ToolDescriptor] = [], @PipelineBuilder query: () -> Query) {
        self.query = query()
        self.tools = tools
    }

    public init(_ query: String, tools: [ToolDescriptor] = []) where Query == Just<String> {
        self.query = Just(value: query)
        self.tools = tools
    }

    public var pipelineGraph: PipelineGraph {
        .leaf(.router(query: query.pipelineGraph, tools: tools))
    }
}

