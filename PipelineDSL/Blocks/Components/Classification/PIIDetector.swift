//
//  PIIDetector.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Personal-data detection spelled as a classifier: a ``TokenClassifier`` whose checkpoint knows
/// `identity.person_name`, `contact.email`, `financial.credit_card`, … (40 PII types, 16 languages).
///
/// `Detect(text, using: PIIDetector())` returns ``LabeledSpans``. An empty result is a clean text only
/// when `status == .evaluated`.
public struct PIIDetector: Classifier {
    public typealias Output = LabeledSpans

    public let spec: ModelSpecDescriptor?

    public init(spec: ModelSpecDescriptor? = nil) {
        self.spec = spec
    }

    public var task: ClassificationTask { .token }
}
