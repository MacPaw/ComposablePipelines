//
//  Model+Context.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// A model call decorated with a context-producing pipeline.
public struct ModelContextStep<
    ContextPipeline: Pipeline,
    Input: Sendable & Codable & Hashable,
    Output: ModelOutput
>: Pipeline, PipelineStructuralNode where ContextPipeline.Output == [ContextItem] {
    public typealias Body = Never

    let contextPipeline: ContextPipeline
    let model: ModelStep<Input, Output>
    let contextSlotID: UUID

    public var body: Never {
        fatalError("ModelContextStep is a structural node")
    }

    public var pipelineGraph: PipelineGraph {
        let config = ModelConfig(
            outputTypeName: model.config.outputTypeName,
            traits: model.config.traits,
            streamingReplySlotID: model.config.streamingReplySlotID,
            contextItemsSlotID: contextSlotID
        )
        return .sequence([
            .leaf(
                .executionStateSet(
                    id: contextSlotID,
                    valueTypeName: String(describing: [ContextItem].self),
                    value: contextPipeline.pipelineGraph,
                    debugLabel: "modelContext",
                    writeKind: .draft
                )
            ),
            .leaf(.model(config: config, arguments: model.arguments)),
        ])
    }
}

public extension ModelStep {
    /// Decorates this model call with context produced by another pipeline.
    ///
    /// ```swift
    /// Model<String>.chat(systemPrompt: "Use relevant memory")
    ///     .message(userMessage)
    ///     .context {
    ///         Memory.recall(userMessage)
    ///     }
    /// ```
    func context<ContextPipeline: Pipeline>(
        @PipelineBuilder _ content: () -> ContextPipeline
    ) -> ModelContextStep<ContextPipeline, Input, Output>
    where ContextPipeline.Output == [ContextItem] {
        ModelContextStep(
            contextPipeline: content(),
            model: self,
            contextSlotID: UUID()
        )
    }
}
