//
//  WorkflowRoute.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

public enum WorkflowRoute: String, Codable, Sendable, Hashable {
    case `default`
    case singleToolCall
    case complexToolCall
}

public struct RouterRequest: Codable, Sendable {
    public let query: String
    public let tools: [ToolDescriptor]

    public init(query: String, tools: [ToolDescriptor]) {
        self.query = query
        self.tools = tools
    }
}

