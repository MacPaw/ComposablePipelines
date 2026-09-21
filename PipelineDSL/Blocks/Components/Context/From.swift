//
//  From.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Wraps any ``ContextItemsProvider`` as a DSL leaf that emits the items
/// produced for the given query. The provider instance is registered with
/// ``GraphEmissionContext`` at lowering; the AST/Compiler graph carries only
/// a per-instance UUID.
///
/// Example:
/// ```swift
/// $ctx.set { From(mySlackProvider, query: "deploy") }
/// $ctx.set { From(mySlackProvider, query: $userMessage) }
/// $ctx.set { From(mySlackProvider) { $userMessage } }
/// ```
public struct From: LeafPipeline {
    public typealias Output = [ContextItem]

    @_spi(Internals) public let providerID: UUID
    public let provider: any ContextItemsProvider
    public let query: () -> any Pipeline

    /// Constant query string.
    public init(_ provider: any ContextItemsProvider, query: String) {
        self.providerID = UUID()
        self.provider = provider
        self.query = { Just(value: query).representedAsPipeline }
    }

    /// Reads the query string from a `Binding<String>` (e.g. `$userMessage`).
    public init(_ provider: any ContextItemsProvider, query: Binding<String>) {
        self.providerID = UUID()
        self.provider = provider
        self.query = { query.representedAsPipeline }
    }

    /// Builds the query string from a sub-pipeline.
    public init<QueryPipeline: Pipeline>(
        _ provider: any ContextItemsProvider,
        @PipelineBuilder query: @Sendable @escaping () -> QueryPipeline
    ) where QueryPipeline.Output == String {
        self.providerID = UUID()
        self.provider = provider
        self.query = { query().representedAsPipeline }
    }
}

extension From {
    public var pipelineGraph: PipelineGraph {
        GraphEmissionContext.current?.recordContextProvider(providerID, provider: provider)
        return .leaf(
            .contextProvide(providerID: providerID, query: query().pipelineGraph)
        )
    }
}
