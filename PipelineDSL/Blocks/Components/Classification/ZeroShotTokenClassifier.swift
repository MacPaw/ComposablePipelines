//
//  ZeroShotTokenClassifier.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Zero-shot token classification: labeled ranges of the text per caller-supplied label, as
/// ``LabeledSpans``.
///
/// Every token is scored against every label independently, so one span may come back once per label
/// it matches. `threshold` is the minimum span score kept; the model card's default is 0.5. The default
/// runtime serves this kind with `LiquidAI/LFM2.5-Encoder-350M-Policy-Linter`, which is what
/// ``PolicyLinter`` names.
public struct ZeroShotTokenClassifier: Classifier {
    public typealias Output = LabeledSpans

    public let labels: [String]
    public let threshold: Float
    public let spec: ModelSpecDescriptor?

    public init(labels: [String], threshold: Float = 0.5, spec: ModelSpecDescriptor? = nil) {
        ClassificationLabels.validate(labels, for: "ZeroShotTokenClassifier")
        precondition((0...1).contains(threshold), "ZeroShotTokenClassifier threshold must be within 0...1")
        self.labels = labels
        self.threshold = threshold
        self.spec = spec
    }

    public var task: ClassificationTask { .zeroShotToken(labels: labels, threshold: threshold) }
}
