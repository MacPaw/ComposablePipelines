//
//  DelegateModelConfig.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import ComposablePipelines

/// The chat requirement delegate subagents use, plus the sampling defaults every subagent starts from.
///
/// A delegate is a **single-model, single-batching-cohort** design: every subagent — worker and judge
/// alike — resolves the agent's shared chat model through the resource heap, so one load serves the
/// entire flood. The delegate does **not** pin a specific model — it asks for a generic chat model and
/// gets whatever the agent registers (currently `LiquidAI/LFM2.5-2.6B`). Isolated *state*, shared
/// *model*.
///
/// - Author: Claude
public enum DelegateModelConfig {

    /// The requirement every delegate subagent uses to acquire the agent's shared chat model. Generic on
    /// purpose: a flood of K subagents all request the same "chat model" and resolve to one heap
    /// resource (one load, K acquisitions), without pinning a particular model id.
    public static let resourceRequirements = ModelSelectionRequirements(traits: .chatCompletion)

    /// Sampling defaults for the two roles in a delegate. Reasoning models emit chain-of-thought before
    /// the answer, so the distilled return must strip CoT (see runbook §2.2) — sampling only shapes
    /// how the tokens are drawn.
    public struct Sampling: Sendable, Hashable {
        /// Nucleus/greedy-leaning temperature. Lower is more reliable; workers vary *upward* across
        /// the delegate for error decorrelation (a later phase), the judge stays low and deterministic.
        public var temperature: Double
        /// Nucleus sampling: the top probability mass to sample from (`1.0` = no nucleus filtering).
        /// Maps to `GenerationParameters.topP`.
        public var topP: Double
        /// Penalty applied to repeated tokens (`1.0` = off).
        public var repetitionPenalty: Double

        public init(temperature: Double, topP: Double, repetitionPenalty: Double) {
            self.temperature = temperature
            self.topP = topP
            self.repetitionPenalty = repetitionPenalty
        }

        /// Worker default: slightly stochastic, biased toward reliable completions. Siblings ramp
        /// *upward* from here for error decorrelation (see ``DelegateDecorrelation``).
        public static let worker = Sampling(temperature: 0.2, topP: 0.95, repetitionPenalty: 1.05)

        /// Judge/verifier: the most reliable pass in the delegate — greedy and deterministic (temperature
        /// `0`, full nucleus, no repetition penalty), so the same candidate set always yields the same
        /// verdict. Deliberately *more* deterministic than ``worker`` — it must not be a copy of it.
        public static let judge = Sampling(temperature: 0.0, topP: 1.0, repetitionPenalty: 1.0)
    }
}
