//
//  Tools.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

// MARK: - Tool schema

/// Minimal JSON-schema-ish shape sufficient for tool calling.
/// Intentionally tiny: add cases only when needed.
public indirect enum JSONSchema: Codable, Sendable, Equatable {
    case object(properties: [String: JSONSchema], required: [String] = [])
    case array(items: JSONSchema)
    case string
    case integer
    case number
    case boolean
    case any
    case oneOf([JSONSchema])
}

public struct ToolDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchema

    public init(name: String, description: String, inputSchema: JSONSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - Tool protocols

/// Base protocol for anything that can appear in `Model(tools:)`.
/// Provides a descriptor (name, description, schema) — no execution surface.
/// Both ``ModelTool`` (client-side, locally callable) and ``AgentTool``
/// (agent-side, descriptor only) conform to this.
public protocol PipelineTool: Sendable {
    var descriptor: ToolDescriptor { get }
}

/// Existential-friendly execution surface for client-side tool dispatch.
/// No associated types — suitable for heterogeneous collections and registry storage.
/// Refines ``Tool``; add ``callJSON(_:)`` for local execution.
public protocol ToolExecutor: PipelineTool {
    func callJSON(_ inputJSON: Data) async throws -> Data
}

/// Typed authoring surface for client-side tools. Refines ``ToolExecutor``.
/// Implement ``call(_:)`` and the static metadata; encoding is handled automatically.
public protocol ModelTool: ToolExecutor {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable & LosslessStringConvertible
    static var name: String { get }
    static var description: String { get }
    static var inputSchema: JSONSchema { get }

    func call(_ input: Input) async throws -> Output
}

public extension ModelTool {
    var descriptor: ToolDescriptor {
        ToolDescriptor(name: Self.name, description: Self.description, inputSchema: Self.inputSchema)
    }

    func callJSON(_ inputJSON: Data) async throws -> Data {
        let input = try JSONDecoder().decode(Input.self, from: inputJSON)
        let output = try await call(input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(output)
    }
}

/// Authoring surface for agent-side tools.
///
/// An `AgentTool` has a descriptor (name, description, schema) but no local implementation —
/// execution always happens inside the Elix agent daemon. Elix ships concrete `AgentTool` types
/// as SDK stubs; developers reference them in `Model(tools:)` so the model sees the schema,
/// but the implementation never crosses the XPC boundary.
///
/// In local execution (`LocalElixClient`), agent tools are not added to the dispatch registry
/// and will not be callable — a clear error surfaces if the model tries to invoke one.
public protocol AgentTool: PipelineTool {
    static var name: String { get }
    static var description: String { get }
    static var inputSchema: JSONSchema { get }
}

public extension AgentTool {
    var descriptor: ToolDescriptor {
        ToolDescriptor(name: Self.name, description: Self.description, inputSchema: Self.inputSchema)
    }
}
