//
//  Memory.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Queries the memory provider registered for this pipeline run.
///
/// Examples:
/// ```swift
/// Memory.recall("user goals")
/// Memory.recall($userMessage, quality: .quick)
/// Memory.recall(quality: .precise) { Model<String>.summarize().message($message) }
/// ```
public struct Memory: LeafPipeline {
    public typealias Output = [ContextItem]

    public let quality: MemoryQueryQuality
    public let query: () -> any Pipeline

    public init(query: String, quality: MemoryQueryQuality = .full) {
        self.quality = quality
        self.query = { Just(value: query).representedAsPipeline }
    }

    public init(query: Binding<String>, quality: MemoryQueryQuality = .full) {
        self.quality = quality
        self.query = { query.representedAsPipeline }
    }

    public init<QueryPipeline: Pipeline>(
        quality: MemoryQueryQuality = .full,
        @PipelineBuilder query: @Sendable @escaping () -> QueryPipeline
    ) where QueryPipeline.Output == String {
        self.quality = quality
        self.query = { query().representedAsPipeline }
    }
}

extension Memory {
    public static func recall(
        _ query: String,
        quality: MemoryQueryQuality = .full
    ) -> Self {
        Self(query: query, quality: quality)
    }

    public static func recall(
        _ query: Binding<String>,
        quality: MemoryQueryQuality = .full
    ) -> Self {
        Self(query: query, quality: quality)
    }

    public static func recall<QueryPipeline: Pipeline>(
        quality: MemoryQueryQuality = .full,
        @PipelineBuilder query: @Sendable @escaping () -> QueryPipeline
    ) -> Self where QueryPipeline.Output == String {
        Self(quality: quality, query: query)
    }

    public var pipelineGraph: PipelineGraph {
        .leaf(.memoryQuery(quality: quality, query: query().pipelineGraph))
    }
}

extension MemoryEntities: ModelOutput {}
extension MemoryItems: ModelOutput {}
extension MemoryWritePlan: ModelOutput {}

extension Memory {
    /// Extracts and normalizes structured memory facts using ordinary model stages.
    ///
    /// This is syntax sugar for a typed entity-extraction model feeding a memory
    /// normalization model. Clients can compose the same stages directly.
    public static func extract(
        from query: String
    ) -> ModelInputStep<ModelStep<String, MemoryEntities>, MemoryItems> {
        Model<MemoryItems>(traits: .memoryNormalization)
            .input {
                Model<MemoryEntities>(traits: .entityExtraction)
                    .input(query)
            }
    }
}

/// Persists entries produced by a pipeline through the memory provider.
public struct MemoryStore<Plan: Pipeline>: LeafPipeline where Plan.Output == MemoryWritePlan {
    public typealias Output = MemoryWritePlan

    public let plan: Plan

    public init(@PipelineBuilder plan: () -> Plan) {
        self.plan = plan()
    }

    public var pipelineGraph: PipelineGraph {
        .leaf(.memoryStore(plan: plan.pipelineGraph))
    }
}

extension Memory {
    public static func store<Plan: Pipeline>(
        @PipelineBuilder plan: () -> Plan
    ) -> MemoryStore<Plan> where Plan.Output == MemoryWritePlan {
        MemoryStore(plan: plan)
    }

    public static func store(_ entry: MemoryEntry) -> MemoryStore<Just<MemoryWritePlan>> {
        MemoryStore {
            Just(value: MemoryWritePlan(entries: [entry]))
        }
    }

    public static func store(_ entries: [MemoryEntry]) -> MemoryStore<Just<MemoryWritePlan>> {
        MemoryStore {
            Just(value: MemoryWritePlan(entries: entries))
        }
    }
}
