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
    public let outputInstructions: String?
    public let traits: ModelSelectionTraits
    public let streamingReplySlotID: UUID?
    /// UUID of an execution slot that holds `[ContextItem]`. Resolved at runtime and injected
    /// as `ModelArgument.contextItems` before `executeModel` is called. `nil` means no context.
    public let contextItemsSlotID: UUID?

    public init(
        outputTypeName: String,
        outputInstructions: String? = nil,
        traits: ModelSelectionTraits = [],
        streamingReplySlotID: UUID? = nil,
        contextItemsSlotID: UUID? = nil
    ) {
        self.outputTypeName = outputTypeName
        self.outputInstructions = outputInstructions
        self.traits = traits
        self.streamingReplySlotID = streamingReplySlotID
        self.contextItemsSlotID = contextItemsSlotID
    }
}
