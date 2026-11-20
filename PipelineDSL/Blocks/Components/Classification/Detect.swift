//
//  Detect.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Finds labeled ranges of a text in one encoder pass and returns ``LabeledSpans``.
///
/// The token-classification verb. Which labels are looked for is the classifier's business:
/// ``TokenClassifier`` uses the checkpoint's own label set, ``ZeroShotTokenClassifier`` the labels
/// written in the pipeline. ``Classify`` is the counterpart that scores the whole text. Both lower to
/// the one `.classify` leaf.
///
/// ```swift
/// $pii.set  { Detect(draft, using: PIIDetector()) }
/// $lint.set { Detect(using: PolicyLinter(rules: ["Flag passwords.", "Flag file system paths."])) { $draft.get() } }
/// ```
///
/// Spans are UTF-16 offsets into exactly the text the step received, with the matched substring
/// repeated in `text`. With no backend the result has `status: .unavailable`; an empty span list is a
/// clean text only when `status == .evaluated`.
public struct Detect<Task: Classifier, Input: Pipeline>: LeafPipeline
where Input.Output == String, Task.Output == LabeledSpans {
    public typealias Output = LabeledSpans

    public let task: Task
    public let input: Input

    public init(using task: Task, @PipelineBuilder text: () -> Input) {
        precondition(task.task.kind.yieldsSpans,
                     "Detect needs a token task; \(task.task.kind) produces label scores — use Classify")
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
