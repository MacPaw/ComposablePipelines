//
//  PolicyLinter.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Policy checking spelled as a classifier: a ``ZeroShotTokenClassifier`` whose labels are rules
/// written in plain language. `Detect(text, using: PolicyLinter(rules:))` returns the spans that
/// violate each rule as ``LabeledSpans``, labeled with the rule text.
///
/// Every token is scored against every rule independently, so one span may come back once per rule it
/// matches. `threshold` is the minimum span score kept; the model card's default is 0.5.
public struct PolicyLinter: Classifier {
    public typealias Output = LabeledSpans

    public let rules: [String]
    public let threshold: Float
    public let spec: ModelSpecDescriptor?

    public init(rules: [String], threshold: Float = 0.5, spec: ModelSpecDescriptor? = nil) {
        ClassificationLabels.validate(rules, for: "PolicyLinter")
        precondition((0...1).contains(threshold), "PolicyLinter threshold must be within 0...1")
        self.rules = rules
        self.threshold = threshold
        self.spec = spec
    }

    public var task: ClassificationTask { .zeroShotToken(labels: rules, threshold: threshold) }
}
