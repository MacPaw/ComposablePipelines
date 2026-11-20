//
//  Tools.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
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

/// Immutable name → executor lookup for `Run`-closure tool dispatch.
///
/// Tool names must be unique — a duplicate is a configuration error and traps with the
/// offending name. Two instances of one tool type (e.g. differently-configured copies)
/// therefore cannot share a registry.
public struct ToolRegistry: Sendable {
    private let toolsByName: [String: any ToolExecutor]

    public init(_ tools: [any ToolExecutor] = []) {
        var byName: [String: any ToolExecutor] = [:]
        byName.reserveCapacity(tools.count)
        for tool in tools {
            let name = tool.descriptor.name
            precondition(byName[name] == nil, "ToolRegistry: duplicate tool name '\(name)'")
            byName[name] = tool
        }
        toolsByName = byName
    }

    public init(_ tools: [any ModelTool]) {
        self.init(tools.map { $0 as any ToolExecutor })
    }

    // MARK: Lookup

    public var isEmpty: Bool { toolsByName.isEmpty }

    public func tool(named name: String) -> (any ToolExecutor)? {
        if let t = toolsByName[name] { return t }
        if let alias = Self.alias(for: name), let t = toolsByName[alias] { return t }
        return nil
    }

    /// Normalize tool-name variants small local models emit (LFM2: `execute_bash`, `create_file`;
    /// Claude-style: `Bash`, `Edit`) onto the canonical tool name, so an otherwise-valid call isn't
    /// rejected as Unknown. Consulted only on an exact-match miss, and the result must itself be a
    /// registered tool — so it can never shadow a real tool or invent one. Lives at dispatch, so it
    /// applies to every decode path (structured channel, LFM2 tokens, XML, JSON).
    static func alias(for name: String) -> String? {
        switch name.lowercased() {
        case "execute", "execute_bash", "run", "run_bash", "run_command", "execute_command",
             "shell", "command", "bash_command", "sh", "terminal":
            return "bash"
        case "create_file", "createfile", "new_file", "save_file", "savefile", "write":
            return "write_file"
        case "read", "cat", "open", "open_file", "view", "view_file":
            return "read_file"
        case "ls", "list", "listdir", "list_directory", "dir":
            return "list_dir"
        case "search", "find", "ripgrep", "rg":
            return "grep"
        case "replace", "str_replace", "edit", "modify", "apply_patch":
            return "edit_file"
        default:
            return nil
        }
    }

    public func descriptorJSON() -> String {
        ToolEncoding.encode(toolsByName.values.map(\.descriptor).sorted { $0.name < $1.name })
    }

    /// The registered names, sorted — what an "unknown tool" answer lists back to the model.
    public var names: [String] { toolsByName.keys.sorted() }

    public func executeJSON(toolName: String, inputJSON: Data) async throws -> Data {
        guard let tool = tool(named: toolName) else {
            throw UnknownToolError(name: toolName, available: names)
        }
        return try await tool.callJSON(inputJSON)
    }
}

/// A tool call named no registered tool. Typed so a telemetry consumer can tell "the model invented a
/// name" from "the tool ran and failed" without parsing a message.
public struct UnknownToolError: Error, Sendable, Equatable, LocalizedError {
    public let name: String
    public let available: [String]

    public init(name: String, available: [String]) {
        self.name = name
        self.available = available
    }

    public var errorDescription: String? { "Unknown tool: \(name)" }
}
