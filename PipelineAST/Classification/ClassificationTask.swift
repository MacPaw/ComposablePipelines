//
//  ClassificationTask.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// What an encoder classification step asks of its model.
///
/// Two result shapes, each in a fixed-label and a zero-shot form. **Sequence** classification scores
/// the whole text and yields ``LabelScores``; **token** classification labels ranges of it and yields
/// ``LabeledSpans``. Fixed-label forms use the checkpoint's own trained label set and take only the
/// text; zero-shot forms score against labels the caller writes in plain language. The runtime selects
/// a resource by ``kind``, so a token request never lands on a sequence model.
///
/// Label wording is load-bearing in the zero-shot forms: the model scores the label text, so phrasing
/// moves accuracy the way a system prompt does for a generative classifier.
public enum ClassificationTask: Codable, Equatable, Hashable, Sendable {
    /// Sequence classification with the checkpoint's own label set: one probability per trained label.
    case sequence
    /// Zero-shot sequence classification: one probability per caller-supplied label, a distribution
    /// (the scores sum to 1) **positionally aligned** with `labels`.
    case zeroShotSequence(labels: [String])
    /// Token classification with the checkpoint's own label set, e.g. a PII detector that knows
    /// `identity.person_name` and `contact.email`.
    case token
    /// Zero-shot token classification: labeled spans per caller-supplied label. Every token is scored
    /// against every label independently, so one span may come back once per label it matches.
    /// `threshold` in `0...1` is the minimum span score kept.
    case zeroShotToken(labels: [String], threshold: Float)

    /// The task's kind without its payload — what selects a resource.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case sequence
        case zeroShotSequence
        case token
        case zeroShotToken
    }

    public var kind: Kind {
        switch self {
        case .sequence: .sequence
        case .zeroShotSequence: .zeroShotSequence
        case .token: .token
        case .zeroShotToken: .zeroShotToken
        }
    }
}

extension ClassificationTask.Kind {
    /// Whether the kind's result is ``LabeledSpans`` (token kinds) rather than ``LabelScores`` (sequence kinds).
    public var yieldsSpans: Bool {
        switch self {
        case .sequence, .zeroShotSequence: false
        case .token, .zeroShotToken: true
        }
    }
}

// MARK: - Validation

extension ClassificationTask {
    /// What makes a task unrunnable. A blank label pools to a zero vector and still scores plausibly;
    /// a duplicate splits its probability mass — neither is something the model can signal about.
    public enum ValidationError: Error, Equatable, Sendable {
        case noLabels
        case blankLabel(index: Int)
        case duplicateLabel(index: Int)
        case thresholdOutOfRange(Float)
    }

    /// Throws when the payload cannot be scored. The DSL preconditions the same rules at authoring time.
    public func validate() throws {
        switch self {
        case .sequence, .token:
            break
        case .zeroShotSequence(let labels):
            try Self.validateLabels(labels)
        case .zeroShotToken(let labels, let threshold):
            try Self.validateLabels(labels)
            guard threshold.isFinite, (0...1).contains(threshold) else {
                throw ValidationError.thresholdOutOfRange(threshold)
            }
        }
    }

    /// The label rule on its own, for the DSL's authoring-time check.
    public static func validateLabels(_ labels: [String]) throws {
        guard !labels.isEmpty else { throw ValidationError.noLabels }
        var seen: Set<String> = []
        for (index, label) in labels.enumerated() {
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.blankLabel(index: index)
            }
            guard seen.insert(label).inserted else { throw ValidationError.duplicateLabel(index: index) }
        }
    }
}

// MARK: - Codable

extension ClassificationTask {
    private enum CodingKeys: String, CodingKey { case sequence, zeroShotSequence, token, zeroShotToken }
    private enum PayloadKeys: String, CodingKey { case labels, threshold }

    /// Decodes the synthesized shape (`{"zeroShotToken":{"labels":[…],"threshold":0.5}}`, `{"token":{}}`)
    /// and validates the payload, so an unrunnable task is refused where it enters.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = container.allKeys.first, container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "ClassificationTask needs exactly one case key"))
        }
        switch key {
        case .sequence:
            _ = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .sequence)
            self = .sequence
        case .token:
            _ = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .token)
            self = .token
        case .zeroShotSequence:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .zeroShotSequence)
            self = .zeroShotSequence(labels: try payload.decode([String].self, forKey: .labels))
        case .zeroShotToken:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .zeroShotToken)
            self = .zeroShotToken(
                labels: try payload.decode([String].self, forKey: .labels),
                threshold: try payload.decode(Float.self, forKey: .threshold))
        }
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "ClassificationTask is not runnable: \(error)"))
        }
    }
}

extension ClassificationTask: CustomStringConvertible {
    /// Payload-free rendering for printers and step labels: `sequence`, `zeroShotSequence(labels: 2)`,
    /// `token`, `zeroShotToken(labels: 3, threshold: 0.5)`.
    public var description: String {
        switch self {
        case .sequence:
            "sequence"
        case .zeroShotSequence(let labels):
            "zeroShotSequence(labels: \(labels.count))"
        case .token:
            "token"
        case .zeroShotToken(let labels, let threshold):
            "zeroShotToken(labels: \(labels.count), threshold: \(threshold))"
        }
    }
}
