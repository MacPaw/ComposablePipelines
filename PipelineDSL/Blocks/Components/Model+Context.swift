//
//  Model+Context.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// A model call decorated with one or more context-producing pipelines.
///
/// Each `.context { }` call appends a new source; all sources are concatenated in order
/// at runtime and injected into the model as `ModelArgument.contextItems`.
public struct ModelContextStep<
    Input: Sendable & Codable & Hashable,
    Output: ModelOutput
>: Pipeline, PipelineStructuralNode {
    public typealias Body = Never

    let contexts: [(slotID: UUID, graph: PipelineGraph)]
    let model: ModelStep<Input, Output>

    public var body: Never {
        fatalError("ModelContextStep is a structural node")
    }

    public var pipelineGraph: PipelineGraph {
        let config = ModelConfig(
            outputTypeName: model.config.outputTypeName,
            traits: model.config.traits,
            streamingReplySlotID: model.config.streamingReplySlotID,
            contextItemsSlotIDs: model.config.contextItemsSlotIDs + contexts.map(\.slotID),
            priorTurnsSlotID: model.config.priorTurnsSlotID
        )
        var items: [PipelineGraph] = contexts.map { (slotID, graph) in
            .leaf(
                .executionStateSet(
                    id: slotID,
                    valueTypeName: String(describing: [ContextItem].self),
                    value: graph,
                    debugLabel: "modelContext",
                    writeKind: .draft
                )
            )
        }
        items.append(.leaf(.model(config: config, arguments: model.arguments)))
        return .sequence(items)
    }
}

public extension ModelContextStep {
    /// Appends another context source. All sources are concatenated in declaration order.
    ///
    /// ```swift
    /// Model<String>.chat(systemPrompt: "Use memory and today's date")
    ///     .message(userMessage)
    ///     .context { Memory.recall(userMessage) }
    ///     .context { Manual([dateItem]) }
    /// ```
    func context<CP: Pipeline>(
        @PipelineBuilder _ content: () -> CP
    ) -> ModelContextStep<Input, Output>
    where CP.Output == [ContextItem] {
        ModelContextStep(
            contexts: contexts + [(UUID(), content().pipelineGraph)],
            model: model
        )
    }
}

public extension ModelStep {
    /// Decorates this model call with a context-producing pipeline.
    ///
    /// Chain multiple `.context { }` calls to accumulate sources:
    /// ```swift
    /// Model<String>.chat(systemPrompt: "Use relevant memory")
    ///     .message(userMessage)
    ///     .context { Memory.recall(userMessage) }
    ///     .context { Manual([dateItem]) }
    /// ```
    func context<CP: Pipeline>(
        @PipelineBuilder _ content: () -> CP
    ) -> ModelContextStep<Input, Output>
    where CP.Output == [ContextItem] {
        ModelContextStep(
            contexts: [(UUID(), content().pipelineGraph)],
            model: self
        )
    }
}
