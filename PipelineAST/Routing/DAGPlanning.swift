//
//  DAGPlanning.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

public struct DAGPlanningRequest: Codable, Sendable {
    public let query: String
    public let tools: [ToolDescriptor]
    public let hints: [String]

    public init(query: String, tools: [ToolDescriptor], hints: [String] = []) {
        self.query = query
        self.tools = tools
        self.hints = hints
    }
}

public struct DAGPlanningResult: Codable, Sendable, Hashable {
    public let text: String?
    public let dag: TaskDAG?

    public init(text: String?, dag: TaskDAG?) {
        self.text = text
        self.dag = dag
    }
}

public struct TaskDAG: Codable, Sendable, Hashable {
    public let nodes: [String: TaskDAGNode]
    public let edges: [[String]]

    public init(nodes: [String: TaskDAGNode], edges: [[String]]) {
        self.nodes = nodes
        self.edges = edges
    }
}

public struct TaskDAGNode: Codable, Sendable, Hashable {
    public let toolId: String
    public let stepDescription: String

    public init(toolId: String, stepDescription: String) {
        self.toolId = toolId
        self.stepDescription = stepDescription
    }

    enum CodingKeys: String, CodingKey {
        case toolId = "tool_id"
        case stepDescription = "step_description"
    }
}
