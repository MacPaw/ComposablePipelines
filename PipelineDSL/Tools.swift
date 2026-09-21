//
//  Tools.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

// MARK: - Encoding

public enum ToolEncoding {
    public static func encode(_ tools: [ToolDescriptor]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(tools)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Registry

public struct ToolRegistry: Sendable {
    private var toolsByName: [String: any ToolExecutor] = [:]

    public init(_ tools: [any ToolExecutor] = []) {
        toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.descriptor.name, $0) })
    }

    public init(_ tools: [any ModelTool]) {
        self.init(tools.map { $0 as any ToolExecutor })
    }

    // MARK: Mutation

    public mutating func register(_ tool: any ToolExecutor) {
        toolsByName[tool.descriptor.name] = tool
    }

    public mutating func unregister(toolNamed name: String) {
        toolsByName[name] = nil
    }

    // MARK: Lookup

    public var isEmpty: Bool { toolsByName.isEmpty }

    public func tool(named name: String) -> (any ToolExecutor)? {
        toolsByName[name]
    }

    public func descriptorJSON() -> String {
        ToolEncoding.encode(toolsByName.values.map(\.descriptor).sorted { $0.name < $1.name })
    }

    public func executeJSON(toolName: String, inputJSON: Data) async throws -> Data {
        guard let tool = tool(named: toolName) else {
            throw NSError(domain: "PipelineDSL.ToolRegistry", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unknown tool: \(toolName)"
            ])
        }
        return try await tool.callJSON(inputJSON)
    }
}
