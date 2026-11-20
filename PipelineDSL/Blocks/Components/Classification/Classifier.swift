//
//  Classifier.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// A concrete encoder task a ``Classify`` or ``Detect`` step runs: the AST task it lowers to, the
/// checkpoint it pins (if any), and the typed result a pipeline reads back.
///
/// Four generic classifiers cover the task matrix — ``SequenceClassifier`` and
/// ``ZeroShotSequenceClassifier`` for label scores, ``TokenClassifier`` and ``ZeroShotTokenClassifier``
/// for spans — and named ones such as ``PromptRouter``, ``PIIDetector`` and ``PolicyLinter`` are the
/// same tasks spelled for their use. The task kind names the model family; `spec` is needed only when
/// a host registers several models of one kind. An empty `spec` pins nothing, like `nil`; a revision or
/// extra files alone are constraints a resource must satisfy.
public protocol Classifier: Sendable {
    associatedtype Output: Codable & Hashable & Sendable
    var task: ClassificationTask { get }
    var spec: ModelSpecDescriptor? { get }
}

/// Labels are a literal at practically every call site, so an empty, blank or duplicate label is an
/// authoring mistake and is caught where it is written.
enum ClassificationLabels {
    static func validate(_ labels: [String], for task: String) {
        do {
            try ClassificationTask.validateLabels(labels)
        } catch {
            preconditionFailure("\(task): \(error) — every label must be present, non-blank and unique")
        }
    }
}
