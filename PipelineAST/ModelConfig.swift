//
//  ModelConfig.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Everything the engine needs to resolve and invoke one model step, apart from the arguments.
///
/// The slot-backed fields (`contextItemsSlotIDs`, `priorTurnsSlotID`, `toolAllowlistSlotID`) are the
/// *deferred* half of the configuration: they name execution slots the walker resolves immediately
/// before the call, so a value decided at run time — by a parent, or by the model itself — can shape a
/// step that was lowered long before. Stored properties are `var` on purpose: the DSL modifiers copy
/// and mutate, so adding a field here never silently drops it at one of the call sites.
public struct ModelConfig: Equatable, Sendable, Hashable {
    public var outputTypeName: String
    public var traits: ModelSelectionTraits
    /// Optional backend selector carried from `ModelSelectionRequirements`. `nil` means "any backend".
    public var backend: ModelBackend?
    /// Optional concrete-model selector (source id / revision) carried from
    /// `ModelSelectionRequirements`. Lets a step target a specific model (e.g. the delegate base model)
    /// rather than resolving by traits alone. `nil` means "any model matching the traits".
    public var spec: ModelSpecDescriptor?
    public var streamingReplySlotID: UUID?
    /// UUIDs of execution slots that each hold `[ContextItem]`. Resolved at runtime and
    /// concatenated in order into `ModelArgument.contextItems` before `executeModel` is called.
    /// Empty means no context injection.
    public var contextItemsSlotIDs: [UUID]
    /// UUID of an execution slot that holds `[ConversationTurn]`. Resolved at runtime and injected
    /// as `ModelArgument.priorTurns` before `executeModel` is called. `nil` means no prior turns.
    public var priorTurnsSlotID: UUID?
    /// UUID of an execution slot that holds `[String]` tool names. Resolved at runtime to **narrow**
    /// `ModelArgument.tools` to the named subset — the catalog itself stays declared in the graph, so
    /// the allowlist can only ever restrict what this step advertises, never extend it.
    ///
    /// This is what lets a caller decide per-run which of a step's tools the model may see: a delegate
    /// parent seeds a subagent's allowlist from the brief it chose, and the subagent's model turn is
    /// rendered with only those tools. `nil` means no narrowing — the full declared catalog is used.
    public var toolAllowlistSlotID: UUID?

    public init(
        outputTypeName: String,
        traits: ModelSelectionTraits = [],
        backend: ModelBackend? = nil,
        spec: ModelSpecDescriptor? = nil,
        streamingReplySlotID: UUID? = nil,
        contextItemsSlotIDs: [UUID] = [],
        priorTurnsSlotID: UUID? = nil,
        toolAllowlistSlotID: UUID? = nil
    ) {
        self.outputTypeName = outputTypeName
        self.traits = traits
        self.backend = backend
        self.spec = spec
        self.streamingReplySlotID = streamingReplySlotID
        self.contextItemsSlotIDs = contextItemsSlotIDs
        self.priorTurnsSlotID = priorTurnsSlotID
        self.toolAllowlistSlotID = toolAllowlistSlotID
    }
}

// MARK: - Codable

extension ModelConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case outputTypeName
        case traits
        case backend
        case spec
        case streamingReplySlotID
        case contextItemsSlotIDs   // current key (array)
        case contextItemsSlotID    // legacy key (single UUID?) — present in old payloads
        case priorTurnsSlotID
        case toolAllowlistSlotID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputTypeName = try c.decode(String.self, forKey: .outputTypeName)
        traits = try c.decode(ModelSelectionTraits.self, forKey: .traits)
        backend = try c.decodeIfPresent(ModelBackend.self, forKey: .backend)
        spec = try c.decodeIfPresent(ModelSpecDescriptor.self, forKey: .spec)
        streamingReplySlotID = try c.decodeIfPresent(UUID.self, forKey: .streamingReplySlotID)
        priorTurnsSlotID = try c.decodeIfPresent(UUID.self, forKey: .priorTurnsSlotID)
        toolAllowlistSlotID = try c.decodeIfPresent(UUID.self, forKey: .toolAllowlistSlotID)

        if let ids = try c.decodeIfPresent([UUID].self, forKey: .contextItemsSlotIDs) {
            contextItemsSlotIDs = ids
        } else if let single = try c.decodeIfPresent(UUID.self, forKey: .contextItemsSlotID) {
            // Migrate payloads produced before the rename: wrap the single ID in an array.
            contextItemsSlotIDs = [single]
        } else {
            contextItemsSlotIDs = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outputTypeName, forKey: .outputTypeName)
        try c.encode(traits, forKey: .traits)
        try c.encodeIfPresent(backend, forKey: .backend)
        try c.encodeIfPresent(spec, forKey: .spec)
        try c.encodeIfPresent(streamingReplySlotID, forKey: .streamingReplySlotID)
        try c.encodeIfPresent(priorTurnsSlotID, forKey: .priorTurnsSlotID)
        try c.encodeIfPresent(toolAllowlistSlotID, forKey: .toolAllowlistSlotID)
        try c.encode(contextItemsSlotIDs, forKey: .contextItemsSlotIDs)
    }
}
