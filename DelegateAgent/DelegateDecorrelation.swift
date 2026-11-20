//
//  DelegateDecorrelation.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import ComposablePipelines

/// Varies workers across the delegate so their errors **decorrelate**. Every worker shares the one base
/// model, so without variation an ensemble just confirms a shared blind spot — aggregation only
/// reduces error when the workers fail in *different* ways. This ramps temperature upward across
/// siblings and offers distinct prompt framings.
///
/// - Author: Claude
public enum DelegateDecorrelation {

    /// Sampling for the `index`-th of `count` sibling workers: sibling 0 keeps the reliable base
    /// temperature, later siblings ramp linearly up to `maxTemperature` for diversity. `topP` and
    /// `repetitionPenalty` are carried from `base`.
    public static func sampling(
        forSibling index: Int,
        of count: Int,
        base: DelegateModelConfig.Sampling = .worker,
        maxTemperature: Double = 0.9
    ) -> DelegateModelConfig.Sampling {
        guard count > 1, index > 0 else { return base }
        let clampedIndex = Swift.min(Swift.max(index, 0), count - 1)
        let fraction = Double(clampedIndex) / Double(count - 1)
        let temperature = base.temperature + (maxTemperature - base.temperature) * fraction
        return DelegateModelConfig.Sampling(
            temperature: temperature,
            topP: base.topP,
            repetitionPenalty: base.repetitionPenalty
        )
    }

    /// Prompt framings that push workers toward different reasoning styles; cycle across siblings.
    public static let framings: [String] = [
        "Answer directly and concisely.",
        "Think step by step, then give the answer.",
        "Consider edge cases and counterexamples first, then answer.",
        "Be skeptical — answer only what you can justify.",
    ]

    /// The framing for the `index`-th sibling (cycles through ``framings``).
    public static func framing(forSibling index: Int) -> String {
        guard !framings.isEmpty else { return "" }
        return framings[((index % framings.count) + framings.count) % framings.count]
    }
}
