//
//  RelevanceRanking.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

public struct RelevanceRankingRequest: Codable, Sendable {
    public let query: String
    public let tools: [ToolDescriptor]
    public let threshold: Float
    /// Maximum number of ranked tools to return (sorted descending by score).
    public let topK: Int

    public init(query: String, tools: [ToolDescriptor], threshold: Float = 0.5, topK: Int = 30) {
        self.query = query
        self.tools = tools
        self.threshold = threshold
        self.topK = topK
    }
}

public struct RelevanceRankingResult: Codable, Sendable, Equatable, Hashable {
    public let rankedTools: [RankedTool]

    public init(rankedTools: [RankedTool]) {
        self.rankedTools = rankedTools
    }
}

public struct RankedTool: Codable, Sendable, Equatable, Hashable {
    public let descriptor: ToolDescriptor
    public let score: Float

    public init(descriptor: ToolDescriptor, score: Float) {
        self.descriptor = descriptor
        self.score = score
    }
}
