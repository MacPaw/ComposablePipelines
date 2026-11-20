//
//  LabeledSpans.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

/// One labeled range of the text a classification step received.
///
/// Offsets are **UTF-16 code units** of that exact text, half-open. UTF-16 is the unit of `NSRange`,
/// attributed strings, JavaScript and ICU, so a host highlights or redacts a span with no conversion and
/// the JSON stays portable; grapheme offsets would depend on the peer's Unicode tables. `text` is the
/// matched substring, so a span is displayable on its own and a mismatch with an edited source is
/// detectable.
public struct LabeledSpan: Codable, Equatable, Hashable, Sendable {
    public let label: String
    public let score: Float
    public let utf16Range: Range<Int>
    public let text: String

    public init(label: String, score: Float, utf16Range: Range<Int>, text: String) {
        self.label = label
        self.score = score
        self.utf16Range = utf16Range
        self.text = text
    }

    /// The span as a `String.Index` range into `source`, or `nil` when the offsets fall outside it.
    public func range(in source: String) -> Range<String.Index>? {
        Self.range(utf16Range, in: source)
    }

    static func range(_ utf16Range: Range<Int>, in source: String) -> Range<String.Index>? {
        let utf16 = source.utf16
        guard utf16Range.lowerBound >= 0, utf16Range.upperBound <= utf16.count else { return nil }
        let lower = utf16.index(utf16.startIndex, offsetBy: utf16Range.lowerBound)
        let upper = utf16.index(utf16.startIndex, offsetBy: utf16Range.upperBound)
        return lower..<upper
    }
}

/// The result of a `.token` or `.zeroShotToken` classification.
///
/// A span matching several rules appears once per label. An empty `spans` means a clean text only when
/// ``isEvaluated``.
public struct LabeledSpans: Codable, Equatable, Hashable, Sendable {
    public let status: ClassificationStatus
    public let spans: [LabeledSpan]

    /// An evaluated result.
    public init(spans: [LabeledSpan]) {
        self.init(status: .evaluated, spans: spans)
    }

    public init(status: ClassificationStatus, spans: [LabeledSpan]) {
        self.status = status
        self.spans = spans
    }

    public var isEvaluated: Bool { status == .evaluated }

    /// The spans carrying `label`, in text order.
    public func spans(labeled label: String) -> [LabeledSpan] {
        spans.filter { $0.label == label }.sorted { $0.utf16Range.lowerBound < $1.utf16Range.lowerBound }
    }

    /// `text` with every span replaced by `replacement(labels)`, where `labels` are the distinct labels
    /// of the spans covering that stretch, in text order.
    ///
    /// Overlapping spans are merged first: a model's spans are disjoint, but widening them to `Character`
    /// boundaries can make two neighbours share a grapheme, and replacing them one by one would leave
    /// part of one in the text. Offsets outside `text` are ignored. The caller decides what an
    /// unevaluated result means; this replaces whatever spans are present.
    public func redacting(_ text: String, with replacement: ([String]) -> String) -> String {
        var regions: [(range: Range<Int>, labels: [String])] = []
        for span in spans.sorted(by: { $0.utf16Range.lowerBound < $1.utf16Range.lowerBound }) {
            if let last = regions.last, span.utf16Range.lowerBound < last.range.upperBound {
                regions[regions.count - 1].range = last.range.lowerBound..<max(last.range.upperBound, span.utf16Range.upperBound)
                if !last.labels.contains(span.label) { regions[regions.count - 1].labels.append(span.label) }
            } else {
                regions.append((span.utf16Range, [span.label]))
            }
        }
        var result = text
        for region in regions.reversed() {
            guard let range = LabeledSpan.range(region.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(region.labels))
        }
        return result
    }

    /// What a pipeline gets when no backend is available: no spans, and no claim that the text is clean.
    public static let unavailable = LabeledSpans(status: .unavailable, spans: [])
}
