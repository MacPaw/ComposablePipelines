//
//  RelevanceRanker.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

public struct RelevanceRanker<Query: Pipeline>: LeafPipeline where Query.Output == String {
    public typealias Output = RelevanceRankingResult

    public let query: Query
    public let tools: [ToolDescriptor]
    public let threshold: Float
    public let topK: Int

    public init(
        tools: [ToolDescriptor],
        threshold: Float = 0.5,
        topK: Int = 30,
        @PipelineBuilder query: () -> Query
    ) {
        self.query = query()
        self.tools = tools
        self.threshold = threshold
        self.topK = topK
    }

    public init(
        _ query: String,
        tools: [ToolDescriptor],
        threshold: Float = 0.5,
        topK: Int = 30
    ) where Query == Just<String> {
        self.query = Just(value: query)
        self.tools = tools
        self.threshold = threshold
        self.topK = topK
    }

    public var pipelineGraph: PipelineGraph {
        .leaf(.relevanceRank(query: query.pipelineGraph, tools: tools, threshold: threshold, topK: topK))
    }
}
