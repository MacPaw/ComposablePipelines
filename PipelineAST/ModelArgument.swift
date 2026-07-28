//
//  ModelArgument.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// A typed model argument. Each built-in case has a fixed string key used as the dictionary key
/// in `ModelArguments`. Use `.custom(key:value:)` for arguments not covered by built-in cases.
public enum ModelArgument: Codable, Sendable, Equatable {

    case systemPrompt(String)
    case message(JSONValue)
    case tools([ToolDescriptor])
    case temperature(Double)
    case maxTokens(Int)
    case contextItems([ContextItem])
    case priorTurns([ConversationTurn])
    case custom(key: String, value: JSONValue)

    public var key: String {
        switch self {
        case .systemPrompt:       return "systemPrompt"
        case .message:            return "message"
        case .tools:              return "tools"
        case .temperature:        return "temperature"
        case .maxTokens:          return "maxTokens"
        case .contextItems:       return "contextItems"
        case .priorTurns:         return "priorTurns"
        case .custom(let k, _):   return k
        }
    }

    public var value: JSONValue {
        switch self {
        case .systemPrompt(let v):  return .string(v)
        case .message(let v):       return v
        case .tools(let v):         return JSONValue(encoding: v)
        case .temperature(let v):   return .double(v)
        case .maxTokens(let v):     return .integer(v)
        case .contextItems(let v):  return JSONValue(encoding: v)
        case .priorTurns(let v):    return JSONValue(encoding: v)
        case .custom(_, let v):     return v
        }
    }
}

// MARK: - Typed accessors

public extension ModelArgument {
    var asSystemPrompt: String?       { guard case .systemPrompt(let v) = self else { return nil }; return v }
    var asMessage: JSONValue?         { guard case .message(let v)      = self else { return nil }; return v }
    var asContextItems: [ContextItem]?    { guard case .contextItems(let v) = self else { return nil }; return v }
    var asPriorTurns: [ConversationTurn]? { guard case .priorTurns(let v)  = self else { return nil }; return v }
    var asTools: [ToolDescriptor]?        { guard case .tools(let v)        = self else { return nil }; return v }
    var asTemperature: Double?        { guard case .temperature(let v)  = self else { return nil }; return v }
    var asMaxTokens: Int?             { guard case .maxTokens(let v)    = self else { return nil }; return v }
}

// MARK: - Codable

// ModelArgument provides an explicit Codable implementation rather than relying on
// synthesis. The `custom` case wraps its JSONValue payload as JSON-encoded Data so
// that it survives BinaryCodable round-trips: BinaryCodable's String primitive
// accepts any valid UTF-8 bytes, which causes JSONValue's "try each type"
// init(from:) to misread binary-encoded arrays as garbage strings.
//
// - Author: Claude
extension ModelArgument {

    private enum CodingKeys: String, CodingKey {
        case systemPrompt, message, tools, temperature, maxTokens, contextItems, priorTurns, custom
    }

    private enum CustomCodingKeys: String, CodingKey {
        case key, value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemPrompt(let v):  try container.encode(v, forKey: .systemPrompt)
        case .message(let v):       try container.encode(v, forKey: .message)
        case .tools(let v):         try container.encode(v, forKey: .tools)
        case .temperature(let v):   try container.encode(v, forKey: .temperature)
        case .maxTokens(let v):     try container.encode(v, forKey: .maxTokens)
        case .contextItems(let v):  try container.encode(v, forKey: .contextItems)
        case .priorTurns(let v):    try container.encode(v, forKey: .priorTurns)
        case .custom(let k, let v):
            var nested = container.nestedContainer(keyedBy: CustomCodingKeys.self, forKey: .custom)
            try nested.encode(k, forKey: .key)
            try nested.encode(JSONEncoder().encode(v), forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.systemPrompt) {
            self = .systemPrompt(try container.decode(String.self, forKey: .systemPrompt))
        } else if container.contains(.message) {
            self = .message(try container.decode(JSONValue.self, forKey: .message))
        } else if container.contains(.tools) {
            self = .tools(try container.decode([ToolDescriptor].self, forKey: .tools))
        } else if container.contains(.temperature) {
            self = .temperature(try container.decode(Double.self, forKey: .temperature))
        } else if container.contains(.maxTokens) {
            self = .maxTokens(try container.decode(Int.self, forKey: .maxTokens))
        } else if container.contains(.contextItems) {
            self = .contextItems(try container.decode([ContextItem].self, forKey: .contextItems))
        } else if container.contains(.priorTurns) {
            self = .priorTurns(try container.decode([ConversationTurn].self, forKey: .priorTurns))
        } else if container.contains(.custom) {
            let nested = try container.nestedContainer(keyedBy: CustomCodingKeys.self, forKey: .custom)
            let key = try nested.decode(String.self, forKey: .key)
            let jsonData = try nested.decode(Data.self, forKey: .value)
            self = .custom(key: key, value: try JSONDecoder().decode(JSONValue.self, from: jsonData))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Unknown ModelArgument case")
            )
        }
    }
}

/// Arguments passed to a model step, keyed by each argument's stable string key.
public typealias ModelArguments = [String: ModelArgument]

public extension ModelArguments {
    subscript(key: ModelArgumentKey) -> ModelArgument? {
        get { self[key.rawValue] }
        set { self[key.rawValue] = newValue }
    }

    var systemPrompt: String        { self[.systemPrompt]?.asSystemPrompt ?? "" }
    var message: JSONValue?         { self[.message]?.asMessage }
    var contextItems: [ContextItem]    { self[.contextItems]?.asContextItems ?? [] }
    var priorTurns: [ConversationTurn] { self[.priorTurns]?.asPriorTurns ?? [] }
    var tools: [ToolDescriptor]        { self[.tools]?.asTools ?? [] }
    var temperature: Double?        { self[.temperature]?.asTemperature }
    var maxTokens: Int?             { self[.maxTokens]?.asMaxTokens }
}
