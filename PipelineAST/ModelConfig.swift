//
//  ModelConfig.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

public struct ModelConfig: Equatable, Sendable, Hashable {
    public let outputTypeName: String
    public let traits: ModelSelectionTraits
    public let streamingReplySlotID: UUID?
    /// UUIDs of execution slots that each hold `[ContextItem]`. Resolved at runtime and
    /// concatenated in order into `ModelArgument.contextItems` before `executeModel` is called.
    /// Empty means no context injection.
    public let contextItemsSlotIDs: [UUID]
    /// UUID of an execution slot that holds `[ConversationTurn]`. Resolved at runtime and injected
    /// as `ModelArgument.priorTurns` before `executeModel` is called. `nil` means no prior turns.
    public let priorTurnsSlotID: UUID?

    public init(
        outputTypeName: String,
        traits: ModelSelectionTraits = [],
        streamingReplySlotID: UUID? = nil,
        contextItemsSlotIDs: [UUID] = [],
        priorTurnsSlotID: UUID? = nil
    ) {
        self.outputTypeName = outputTypeName
        self.traits = traits
        self.streamingReplySlotID = streamingReplySlotID
        self.contextItemsSlotIDs = contextItemsSlotIDs
        self.priorTurnsSlotID = priorTurnsSlotID
    }
}

// MARK: - Codable

extension ModelConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case outputTypeName
        case traits
        case streamingReplySlotID
        case contextItemsSlotIDs   // current key (array)
        case contextItemsSlotID    // legacy key (single UUID?) — present in old payloads
        case priorTurnsSlotID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputTypeName = try c.decode(String.self, forKey: .outputTypeName)
        traits = try c.decode(ModelSelectionTraits.self, forKey: .traits)
        streamingReplySlotID = try c.decodeIfPresent(UUID.self, forKey: .streamingReplySlotID)
        priorTurnsSlotID = try c.decodeIfPresent(UUID.self, forKey: .priorTurnsSlotID)

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
        try c.encodeIfPresent(streamingReplySlotID, forKey: .streamingReplySlotID)
        try c.encodeIfPresent(priorTurnsSlotID, forKey: .priorTurnsSlotID)
        try c.encode(contextItemsSlotIDs, forKey: .contextItemsSlotIDs)
    }
}
