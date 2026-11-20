//
//  LabelScores.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

/// The result of a sequence classification: one probability per label.
///
/// `scores` is **positionally aligned** with `labels`. For a zero-shot task the labels are the ones the
/// step declared, echoed back; for a fixed-label task they are the checkpoint's own, which the pipeline
/// has no other way to learn.
public struct LabelScores: Codable, Equatable, Hashable, Sendable {
    public let status: ClassificationStatus
    public let labels: [String]
    public let scores: [Float]

    /// An evaluated result.
    public init(labels: [String], scores: [Float]) {
        self.init(status: .evaluated, labels: labels, scores: scores)
    }

    public init(status: ClassificationStatus, labels: [String], scores: [Float]) {
        precondition(labels.count == scores.count, "LabelScores needs one score per label")
        self.status = status
        self.labels = labels
        self.scores = scores
    }

    /// Refuses a payload whose labels and scores disagree in length, so the alignment invariant holds
    /// for decoded results too.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(ClassificationStatus.self, forKey: .status)
        let labels = try container.decode([String].self, forKey: .labels)
        let scores = try container.decode([Float].self, forKey: .scores)
        guard labels.count == scores.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .scores, in: container,
                debugDescription: "LabelScores carries \(labels.count) labels but \(scores.count) scores")
        }
        self.init(status: status, labels: labels, scores: scores)
    }

    private enum CodingKeys: String, CodingKey { case status, labels, scores }

    public var isEvaluated: Bool { status == .evaluated }

    /// The winning label's index, or `nil` when nothing was scored.
    ///
    /// Plain argmax, no confidence threshold: a low-margin decision is still a decision. `nil` whenever
    /// the step did not run, so a pipeline takes its own default branch rather than label 0.
    public var topIndex: Int? {
        guard isEvaluated else { return nil }
        return scores.indices.max(by: { scores[$0] < scores[$1] })
    }

    /// The winning label's text, or `nil` when nothing was scored.
    public var topLabel: String? {
        topIndex.map { labels[$0] }
    }

    /// The score of `label`, or `nil` when the label was not scored.
    public func score(for label: String) -> Float? {
        labels.firstIndex(of: label).map { scores[$0] }
    }

    /// What a pipeline gets when no backend is available: nothing scored, `topIndex` is `nil`.
    public static let unavailable = LabelScores(status: .unavailable, labels: [], scores: [])
}

/// The result of `PromptRouter`, which is a zero-shot sequence classification over routing lanes.
public typealias PromptRouteDecision = LabelScores

extension LabelScores {
    /// Routing spelling of ``unavailable``: no router available, so the pipeline takes its own default lane.
    public static var undecided: LabelScores { .unavailable }
}
