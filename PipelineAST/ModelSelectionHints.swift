//
//  ModelSelectionHints.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Combined trait set for model selection — describes characteristics a model offers
/// and preferences a caller requests. Traits are advisory, not contractual.
///
/// Used for agent-side heap matching (`ModelExecutionResource.satisfies`).
/// Bit layout preserves the existing `ModelSelectionHints` wire values for IPC compatibility.
public struct ModelSelectionTraits: OptionSet, Codable, Equatable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // MARK: - Response characteristics (IPC-stable bits from ModelSelectionHints)
    /// Prefer low-latency inference.
    public static let quick      = Self(rawValue: 1 << 0)
    /// Prefer local (on-device) execution.
    public static let localOnly  = Self(rawValue: 1 << 1)
    /// Model is instruction-tuned.
    public static let instruct   = Self(rawValue: 1 << 2)
    /// Model supports multi-step reasoning.
    public static let reasoning  = Self(rawValue: 1 << 3)
    /// Model supports streaming output.
    public static let streaming  = Self(rawValue: 1 << 4)

    // MARK: - Resource characteristics (from ModelPerformanceRequirements)
    /// Prefer low-memory footprint.
    public static let lowMemory  = Self(rawValue: 1 << 5)
    /// Prefer low inference cost.
    public static let lowCost    = Self(rawValue: 1 << 6)

    // MARK: - Purpose (replaces ModelPurpose enum; bits 7–12 are IPC-stable)
    /// Conversational AI with optional tool use.
    public static let chatCompletion       = Self(rawValue: 1 << 7)
    /// Open-ended text / prose generation.
    public static let textGeneration       = Self(rawValue: 1 << 8)
    /// Text summarization.
    public static let summarize            = Self(rawValue: 1 << 9)
    /// Structured label output.
    public static let textClassification   = Self(rawValue: 1 << 10)
    /// Embeddings generation.
    public static let embeddingsGeneration = Self(rawValue: 1 << 11)
    /// Structured reasoning with tool awareness.
    public static let taskPlanning         = Self(rawValue: 1 << 12)
    /// Extract relevant memory entities for a query.
    public static let memoryExtraction     = Self(rawValue: 1 << 13)
    /// Extract typed entities and their schema-defined keys from input.
    public static let entityExtraction     = Self(rawValue: 1 << 14)
    /// Normalize extracted entities into structured memory facts.
    public static let memoryNormalization  = Self(rawValue: 1 << 15)
    /// Content-safety guardrail classification.
    public static let guardrailClassification = Self(rawValue: 1 << 16)
}
