//
//  Classify.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Scores a whole text in one encoder pass and returns ``LabelScores``.
///
/// The sequence-classification verb. Which labels are scored is the classifier's business:
/// ``ZeroShotSequenceClassifier`` scores the labels written in the pipeline, ``SequenceClassifier`` the
/// checkpoint's own. ``Detect`` is the counterpart for token classification, which labels *ranges* of
/// the text. Both lower to the one `.classify` leaf.
///
/// ```swift
/// $gate.set  { Classify(prompt, using: PromptRouter(lanes: ["answer from knowledge", "needs a tool"])) }
/// $topic.set { Classify(using: ZeroShotSequenceClassifier(labels: topics)) { $draft.get() } }
/// ```
///
/// With no backend for the task the result has `status: .unavailable` and `topIndex == nil`; check it
/// before treating a score as a decision.
public struct Classify<Task: Classifier, Input: Pipeline>: LeafPipeline
where Input.Output == String, Task.Output == LabelScores {
    public typealias Output = LabelScores

    public let task: Task
    public let input: Input

    public init(using task: Task, @PipelineBuilder text: () -> Input) {
        precondition(!task.task.kind.yieldsSpans,
                     "Classify needs a sequence task; \(task.task.kind) produces spans — use Detect")
        self.task = task
        self.input = text()
    }

    public init(_ text: String, using task: Task) where Input == Just<String> {
        self.init(using: task) { Just(value: text) }
    }

    public var pipelineGraph: PipelineGraph {
        .leaf(.classify(text: input.pipelineGraph, task: task.task, spec: task.spec))
    }
}
