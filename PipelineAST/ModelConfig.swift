//
//  ModelConfig.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

public struct ModelConfig: Codable, Equatable, Sendable, Hashable {
    public let outputTypeName: String
    public let traits: ModelSelectionTraits
    public let streamingReplySlotID: UUID?
    /// UUID of an execution slot that holds `[ContextItem]`. Resolved at runtime and injected
    /// as `ModelArgument.contextItems` before `executeModel` is called. `nil` means no context.
    public let contextItemsSlotID: UUID?
    /// UUID of an execution slot that holds `[ConversationTurn]`. Resolved at runtime and injected
    /// as `ModelArgument.priorTurns` before `executeModel` is called. `nil` means no prior turns.
    public let priorTurnsSlotID: UUID?

    public init(
        outputTypeName: String,
        traits: ModelSelectionTraits = [],
        streamingReplySlotID: UUID? = nil,
        contextItemsSlotID: UUID? = nil,
        priorTurnsSlotID: UUID? = nil
    ) {
        self.outputTypeName = outputTypeName
        self.traits = traits
        self.streamingReplySlotID = streamingReplySlotID
        self.contextItemsSlotID = contextItemsSlotID
        self.priorTurnsSlotID = priorTurnsSlotID
    }
}
