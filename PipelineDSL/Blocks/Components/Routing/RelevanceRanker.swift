//
//  RelevanceRanker.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

public struct RelevanceRanker<Query: Pipeline>: LeafPipeline where Query.Output == String {
    public typealias Output = RelevanceRankingResult

    public let query: Query
    public let tools: [ToolDescriptor]
    public let topK: Int

    public init(
        tools: [ToolDescriptor],
        topK: Int = 30,
        @PipelineBuilder query: () -> Query
    ) {
        self.query = query()
        self.tools = tools
        self.topK = topK
    }

    public init(
        _ query: String,
        tools: [ToolDescriptor],
        topK: Int = 30
    ) where Query == Just<String> {
        self.query = Just(value: query)
        self.tools = tools
        self.topK = topK
    }

    public var pipelineGraph: PipelineGraph {
        .leaf(.relevanceRank(query: query.pipelineGraph, tools: tools, topK: topK))
    }
}
