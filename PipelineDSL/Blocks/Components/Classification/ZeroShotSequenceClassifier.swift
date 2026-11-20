//
//  ZeroShotSequenceClassifier.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Zero-shot sequence classification: scores a text against caller-supplied labels in one encoder pass.
///
/// The result is a ``LabelScores`` distribution aligned with `labels`. Label wording is load-bearing —
/// the model scores the label text — so treat labels as tunable, not fixed. The default runtime serves
/// this kind with `LiquidAI/LFM2.5-Encoder-350M-Prompt-Router`.
public struct ZeroShotSequenceClassifier: Classifier {
    public typealias Output = LabelScores

    public let labels: [String]
    public let spec: ModelSpecDescriptor?

    public init(labels: [String], spec: ModelSpecDescriptor? = nil) {
        ClassificationLabels.validate(labels, for: "ZeroShotSequenceClassifier")
        self.labels = labels
        self.spec = spec
    }

    public var task: ClassificationTask { .zeroShotSequence(labels: labels) }
}
