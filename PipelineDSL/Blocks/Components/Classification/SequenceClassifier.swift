//
//  SequenceClassifier.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Sequence classification with the checkpoint's own label set: ``LabelScores`` over the labels the
/// model was trained on, echoed back so the pipeline can read them.
///
/// The caller supplies only the text. The default runtime ships no fixed-label sequence checkpoint, so
/// this task yields `status: .unavailable` until a host registers one (a sentiment or intent model).
public struct SequenceClassifier: Classifier {
    public typealias Output = LabelScores

    public let spec: ModelSpecDescriptor?

    public init(spec: ModelSpecDescriptor? = nil) {
        self.spec = spec
    }

    public var task: ClassificationTask { .sequence }
}
