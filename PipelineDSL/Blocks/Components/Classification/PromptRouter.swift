//
//  PromptRouter.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Routing spelled as a classifier: a ``ZeroShotSequenceClassifier`` whose labels are the lanes a
/// pipeline can take.
///
/// `Classify(prompt, using: PromptRouter(lanes:))` returns a ``PromptRouteDecision`` aligned with
/// `lanes`; read `topIndex` to branch. With no classification backend it is
/// ``PromptRouteDecision/undecided`` (`status == .unavailable`, `topIndex == nil`), so the pipeline can
/// take its own default branch.
public struct PromptRouter: Classifier {
    public typealias Output = PromptRouteDecision

    /// Free-text lane descriptions. Order is significant — it is how the decision is read back.
    /// Wording is load-bearing: the score is a softmax over the lane *text*, so treat it as tunable.
    public let lanes: [String]
    public let spec: ModelSpecDescriptor?

    public init(lanes: [String], spec: ModelSpecDescriptor? = nil) {
        ClassificationLabels.validate(lanes, for: "PromptRouter")
        self.lanes = lanes
        self.spec = spec
    }

    public var task: ClassificationTask { .zeroShotSequence(labels: lanes) }
}
