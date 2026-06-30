//
//  Model.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

// MARK: - ModelOutput

public protocol ModelOutput: Codable, Hashable, Sendable {
    static var outputTypeName: String { get }
}

public extension ModelOutput {
    static var outputTypeName: String { String(describing: Self.self) }
}

extension String: ModelOutput {
    public static let outputTypeName = "String"
}
extension Bool: ModelOutput {}
extension ModelTurn: ModelOutput {
    // outputTypeName is defined on ModelTurn in PipelineAST.
}

// MARK: - Model builder

/// Fluent builder that constructs a ``ModelStep`` for inclusion in a pipeline graph.
///
/// Call builder methods to set static arguments, then finalise with ``message(_:)`` to produce
/// a ``ModelStep`` that lowers to ``PipelineGraphLeaf/model``.
///
/// ```swift
/// Model<String>()
///     .systemPrompt("You are a helpful assistant.")
///     .tools([ReadFileTool.descriptor])
///     .message(userInput)
/// ```
public struct Model<Output: ModelOutput>: Sendable {
    private var config: ModelConfig
    private var arguments: ModelArguments

    // MARK: Designated init

    public init(requirements: ModelSelectionRequirements = .default) {
        config = ModelConfig(
            outputTypeName: Output.outputTypeName,
            traits: requirements.traits
        )
        arguments = [:]
    }

    // MARK: Convenience inits

    /// Shorthand for specific traits (typically a purpose bit plus capability bits).
    public init(traits: ModelSelectionTraits) {
        self.init(requirements: .init(traits: traits))
    }

    /// Shorthand selecting a specific backend with traits.
    public init(traits: ModelSelectionTraits, backend: ModelBackend) {
        self.init(requirements: .init(backend: backend, traits: traits))
    }

    // MARK: Builder methods

    /// Adds a custom or provider-specific argument (e.g. `enable_thinking`, `today`).
    ///
    /// Maps to ``ModelArgument/custom(key:value:)`` keyed by `key.rawValue`.
    /// Use ``ModelArgumentKey`` static members for built-in arguments or extend it for
    /// provider-specific ones:
    ///
    /// ```swift
    /// extension ModelArgumentKey {
    ///     static let enableThinking: Self = "enable_thinking"
    /// }
    ///
    /// Model<String>.chat(systemPrompt: "Think carefully.")
    ///     .parameter(.enableThinking, true)
    ///     .message(userInput)
    /// ```
    public func parameter<V: Encodable & Sendable>(_ key: ModelArgumentKey, _ value: V) -> Self {
        precondition(
            !ModelArgumentKey.builtInKeys.contains(key),
            "'\(key.rawValue)' is a built-in argument — use the dedicated builder method instead of .parameter(_:_:)"
        )
        var copy = self
        copy.arguments[key.rawValue] = .custom(key: key.rawValue, value: JSONValue(encoding: value))
        return copy
    }

    public func requirements(_ value: ModelSelectionRequirements) -> Self {
        var copy = self
        copy.config = ModelConfig(
            outputTypeName: config.outputTypeName,
            traits: value.traits,
            streamingReplySlotID: config.streamingReplySlotID,
            contextItemsSlotID: config.contextItemsSlotID,
            priorTurnsSlotID: config.priorTurnsSlotID
        )
        return copy
    }

    public func systemPrompt(_ value: String) -> Self {
        var copy = self
        copy.arguments[ModelArgument.systemPrompt("").key] = .systemPrompt(value)
        return copy
    }

    public func tools(_ value: [ToolDescriptor]) -> Self {
        var copy = self
        copy.arguments[ModelArgument.tools([]).key] = .tools(value)
        return copy
    }

    public func temperature(_ value: Double) -> Self {
        var copy = self
        copy.arguments[ModelArgument.temperature(0).key] = .temperature(value)
        return copy
    }

    public func maxTokens(_ value: Int) -> Self {
        var copy = self
        copy.arguments[ModelArgument.maxTokens(0).key] = .maxTokens(value)
        return copy
    }

    /// Registers a context-items binding: the engine reads `[ContextItem]` from the binding's slot
    /// at execution time and injects it as ``ModelArgument/contextItems(_:)`` before calling the resource.
    public func contextItems(_ binding: Binding<[ContextItem]>) -> Self {
        var copy = self
        copy.config = ModelConfig(
            outputTypeName: config.outputTypeName,
            traits: config.traits,
            streamingReplySlotID: config.streamingReplySlotID,
            contextItemsSlotID: binding.id,
            priorTurnsSlotID: config.priorTurnsSlotID
        )
        return copy
    }

    /// Injects prior conversation turns directly (static value, captured at pipeline build time).
    public func priorTurns(_ value: [ConversationTurn]) -> Self {
        var copy = self
        copy.arguments[ModelArgument.priorTurns([]).key] = .priorTurns(value)
        return copy
    }

    /// Registers a prior-turns binding: the engine reads `[ConversationTurn]` from the binding's
    /// slot at execution time and injects it as ``ModelArgument/priorTurns(_:)`` before calling the resource.
    public func priorTurns(_ binding: Binding<[ConversationTurn]>) -> Self {
        var copy = self
        copy.config = ModelConfig(
            outputTypeName: config.outputTypeName,
            traits: config.traits,
            streamingReplySlotID: config.streamingReplySlotID,
            contextItemsSlotID: config.contextItemsSlotID,
            priorTurnsSlotID: binding.id
        )
        return copy
    }

    // MARK: Finaliser

    /// Attaches the user message and returns the fully configured ``ModelStep``.
    ///
    /// Runs ``ModelBuildDiagnosticEmitter/validate(config:arguments:)`` at build time to surface
    /// invalid argument combinations (e.g. tools on an embedding model) to stderr.
    public func message<Input: Sendable & Codable & Hashable>(_ value: Input) -> ModelStep<Input, Output> {
        var args = arguments
        args[ModelArgument.message(.null).key] = .message(JSONValue(encoding: value))
        ModelBuildDiagnosticEmitter.validate(config: config, arguments: args)
        return ModelStep(config: config, arguments: args)
    }

    /// Attaches a statically available typed input.
    public func input<Input: Sendable & Codable & Hashable>(_ value: Input) -> ModelStep<Input, Output> {
        message(value)
    }

    /// Evaluates `input` at execution time and passes its encoded output to the model.
    public func input<InputPipeline: Pipeline>(
        @PipelineBuilder _ input: () -> InputPipeline
    ) -> ModelInputStep<InputPipeline, Output> {
        ModelBuildDiagnosticEmitter.validate(config: config, arguments: arguments)
        return ModelInputStep(config: config, arguments: arguments, input: input())
    }
}

// MARK: - Purpose-specific factory methods

/// Factory methods that set the purpose trait automatically and accept **only the arguments
/// that are relevant for that purpose**, making misuse visible at the call site.
///
/// The returned builder can still be chained with ``Model/parameter(_:_:)`` for provider-specific
/// extras before finalising with ``Model/message(_:)``.
public extension Model {

    /// Chat completion — conversational AI with optional tool use.
    ///
    /// Relevant arguments: `systemPrompt`, `tools`, `temperature`, `maxTokens`.
    static func chat(
        systemPrompt: String? = nil,
        tools: [ToolDescriptor] = [],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        traits: ModelSelectionTraits = []
    ) -> Self {
        var m = Self(traits: .chatCompletion.union(traits))
        if let sp = systemPrompt { m = m.systemPrompt(sp) }
        if !tools.isEmpty { m = m.tools(tools) }
        if let t = temperature { m = m.temperature(t) }
        if let mt = maxTokens { m = m.maxTokens(mt) }
        return m
    }

    /// Open-ended text / prose generation.
    ///
    /// Relevant arguments: `systemPrompt`, `temperature`, `maxTokens`.
    static func generate(
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        traits: ModelSelectionTraits = []
    ) -> Self {
        var m = Self(traits: .textGeneration.union(traits))
        if let sp = systemPrompt { m = m.systemPrompt(sp) }
        if let t = temperature { m = m.temperature(t) }
        if let mt = maxTokens { m = m.maxTokens(mt) }
        return m
    }

    /// Summarization — `maxTokens` controls output length.
    ///
    /// Relevant arguments: `systemPrompt`, `maxTokens`.
    static func summarize(
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        traits: ModelSelectionTraits = []
    ) -> Self {
        var m = Self(traits: .summarize.union(traits))
        if let sp = systemPrompt { m = m.systemPrompt(sp) }
        if let mt = maxTokens { m = m.maxTokens(mt) }
        return m
    }

    /// Text classification — structured label output.
    ///
    /// Relevant arguments: `systemPrompt`.
    static func classify(
        systemPrompt: String? = nil,
        traits: ModelSelectionTraits = []
    ) -> Self {
        var m = Self(traits: .textClassification.union(traits))
        if let sp = systemPrompt { m = m.systemPrompt(sp) }
        return m
    }

    /// Embeddings — message only; other arguments are ignored by embedding backends.
    static func embed(traits: ModelSelectionTraits = []) -> Self {
        Self(traits: .embeddingsGeneration.union(traits))
    }

    /// Task planning — structured reasoning with tool awareness.
    ///
    /// Relevant arguments: `systemPrompt`, `tools`, `temperature`.
    static func plan(
        systemPrompt: String? = nil,
        tools: [ToolDescriptor] = [],
        temperature: Double? = nil,
        traits: ModelSelectionTraits = []
    ) -> Self {
        var m = Self(traits: .taskPlanning.union(traits))
        if let sp = systemPrompt { m = m.systemPrompt(sp) }
        if !tools.isEmpty { m = m.tools(tools) }
        if let t = temperature { m = m.temperature(t) }
        return m
    }
}

// MARK: - ModelStep

/// A fully configured model call that lowers to ``PipelineGraphLeaf/model``.
public struct ModelStep<Input: Sendable & Codable & Hashable, Output: ModelOutput>: LeafPipeline {
    let config: ModelConfig
    let arguments: ModelArguments

    public var pipelineGraph: PipelineGraph {
        .leaf(.model(config: config, arguments: arguments))
    }
}

/// A model call whose typed input is produced by another pipeline.
public struct ModelInputStep<InputPipeline: Pipeline, Output: ModelOutput>: LeafPipeline
where InputPipeline.Output: Sendable & Codable & Hashable {
    let config: ModelConfig
    let arguments: ModelArguments
    let input: InputPipeline

    public var pipelineGraph: PipelineGraph {
        .leaf(
            .modelInput(
                config: config,
                arguments: arguments,
                input: input.pipelineGraph
            )
        )
    }
}
