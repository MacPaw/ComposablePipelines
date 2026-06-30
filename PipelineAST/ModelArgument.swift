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
