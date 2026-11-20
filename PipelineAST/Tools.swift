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
public indirect enum JSONSchema: Codable, Sendable, Equatable, Hashable {
    case object(properties: [String: JSONSchema], required: [String] = [])
    case array(items: JSONSchema)
    case string
    case integer
    case number
    case boolean
    case any
    case oneOf([JSONSchema])
    /// `schema` with a `description`, the one place a tool says what a parameter means where the
    /// model writes it. Every converter to standard JSON Schema merges the text into the wrapped
    /// schema's object, so `{"type":"string","description":…}` is what a model sees.
    ///
    /// - Author: Claude
    case described(String, JSONSchema)
    /// A string that must be one of `values`: `{"type":"string","enum":[…]}`. Additive and without
    /// an `IPC_API_VERSION` bump: a peer from before it decodes every schema that does not use it.
    ///
    /// - Author: Claude
    case enumeration([String])
}

extension JSONSchema {
    /// `.described(description, self)`.
    public func described(_ description: String) -> JSONSchema {
        .described(description, self)
    }

    /// The schema as a standard JSON Schema object, the shape models and OpenAI-compatible servers
    /// read: `{"type":"object","properties":{"path":{"type":"string","description":…}}}`. The
    /// synthesized `Codable` puts Swift case names on the wire instead, so every converter goes
    /// through this one. A description merges into the node it wraps, the outermost winning.
    /// `includingEmptyRequired` keeps `"required": []` on an object that has none; the local engine
    /// has always sent it, and dropping it would change the prompt its measurements were taken on.
    ///
    /// - Author: Claude
    public func standardObject(includingEmptyRequired: Bool = false) -> [String: Any] {
        switch self {
        case .string:  return ["type": "string"]
        case .integer: return ["type": "integer"]
        case .number:  return ["type": "number"]
        case .boolean: return ["type": "boolean"]
        case .any:     return [:]  // the empty schema accepts anything
        case .array(let items):
            return ["type": "array", "items": items.standardObject(includingEmptyRequired: includingEmptyRequired)]
        case .object(let properties, let required):
            var out: [String: Any] = [
                "type": "object",
                "properties": properties.mapValues { $0.standardObject(includingEmptyRequired: includingEmptyRequired) },
            ]
            if includingEmptyRequired || !required.isEmpty { out["required"] = required }
            return out
        case .oneOf(let schemas):
            return ["oneOf": schemas.map { $0.standardObject(includingEmptyRequired: includingEmptyRequired) }]
        case .enumeration(let values):
            return ["type": "string", "enum": values]
        case .described(let description, let schema):
            return schema.standardObject(includingEmptyRequired: includingEmptyRequired)
                .merging(["description": description]) { _, new in new }
        }
    }
}

public struct ToolDescriptor: Codable, Sendable, Equatable, Hashable {
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
public protocol PipelineTool: Sendable {
    var descriptor: ToolDescriptor { get }
}

/// Existential-friendly execution surface for client-side tool dispatch.
/// No associated types — suitable for heterogeneous collections and registry storage.
/// Refines ``PipelineTool``; adds ``callJSON(_:)`` for local execution.
public protocol ToolExecutor: PipelineTool {
    func callJSON(_ inputJSON: Data) async throws -> Data
}

/// Typed authoring surface for client-side tools. Refines ``ToolExecutor``.
/// Implement ``call(_:)`` and the static metadata; encoding is handled automatically.
public protocol ModelTool: ToolExecutor {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable
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
