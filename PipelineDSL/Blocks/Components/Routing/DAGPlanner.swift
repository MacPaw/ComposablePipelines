//
//  DAGPlanner.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

public struct DAGPlanner<Query: Pipeline>: LeafPipeline where Query.Output == String {
    public typealias Output = DAGPlanningResult

    public let query: Query
    public let tools: [ToolDescriptor]
    public let hints: [String]

    public init(
        tools: [ToolDescriptor],
        hints: [String] = [],
        @PipelineBuilder query: () -> Query
    ) {
        self.query = query()
        self.tools = tools
        self.hints = hints
    }

    public init(
        _ query: String,
        tools: [ToolDescriptor],
        hints: [String] = []
    ) where Query == Just<String> {
        self.query = Just(value: query)
        self.tools = tools
        self.hints = hints
    }

    public var pipelineGraph: PipelineGraph {
        .leaf(.dagPlan(query: query.pipelineGraph, tools: tools, hints: hints))
    }
}

