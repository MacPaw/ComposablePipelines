//
//  TokenClassifier.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Token classification with the checkpoint's own label set: labeled ranges of the text as
/// ``LabeledSpans``.
///
/// The caller supplies only the text; the labels are the model's. The default runtime serves this kind
/// with `LiquidAI/LFM2.5-Encoder-350M-PII-Detector`, which is what ``PIIDetector`` names.
public struct TokenClassifier: Classifier {
    public typealias Output = LabeledSpans

    public let spec: ModelSpecDescriptor?

    public init(spec: ModelSpecDescriptor? = nil) {
        self.spec = spec
    }

    public var task: ClassificationTask { .token }
}
