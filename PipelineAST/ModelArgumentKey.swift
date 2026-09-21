//
//  ModelArgumentKey.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

//
//  ModelArgumentKey.swift
//

import Foundation

/// Ergonomic string-backed key for use in the ``Model`` builder.
///
/// All built-in argument names are available as static members (`ModelArgumentKey.systemPrompt`, etc.).
/// Extend with your own `static let` members for provider-specific parameters:
///
/// ```swift
/// extension ModelArgumentKey {
///     static let enableThinking: Self = "enable_thinking"
///     static let today:          Self = "today"
/// }
///
/// // Usage:
/// Model<String>()
///     .systemPrompt("Think carefully.")
///     .parameter(.enableThinking, true)
///     .parameter(.today, Date())
///     .message(userInput)
/// ```
///
/// > Note: `ModelArgumentKey` is a builder-only type. It does **not** change
/// > `ModelArguments = [String: ModelArgument]`; keys are stored as plain `String` values
/// > in the underlying dictionary.
public struct ModelArgumentKey: RawRepresentable, Hashable, Sendable, Equatable,
    ExpressibleByStringLiteral, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// Built-in keys matching each ``ModelArgument`` case.
public extension ModelArgumentKey {
    static let systemPrompt: Self = "systemPrompt"
    static let message:      Self = "message"
    static let tools:        Self = "tools"
    static let temperature:  Self = "temperature"
    static let maxTokens:    Self = "maxTokens"
    static let contextItems: Self = "contextItems"
    static let priorTurns:   Self = "priorTurns"

    /// Rules for guardrail classification. Used by `GuardrailClassification` internally.
    static let guardrailRules: Self = "guardrailRules"

    /// Keys reserved for built-in arguments. Passing any of these to
    /// ``Model/parameter(_:_:)`` is a programming error — use the dedicated builder methods.
    static let builtInKeys: Set<Self> = [
        .systemPrompt, .message, .tools, .temperature, .maxTokens, .contextItems, .priorTurns
    ]
}
