//
//  ClassificationResultTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST

/// The wire-level result types of a classification step: argmax rules, the unavailable marker, and the
/// UTF-16 span contract.
final class ClassificationResultTests: XCTestCase {

    func testTopIndexIsPlainArgmax() {
        // No confidence threshold: a narrow margin is still a decision.
        XCTAssertEqual(LabelScores(labels: ["a", "b"], scores: [0.5009, 0.4991]).topIndex, 0)
        XCTAssertEqual(LabelScores(labels: ["a", "b"], scores: [0.4991, 0.5009]).topLabel, "b")
        XCTAssertNil(LabelScores(labels: [], scores: []).topIndex)
        XCTAssertEqual(LabelScores(labels: ["a", "b"], scores: [0.25, 0.75]).score(for: "b"), 0.75)
        XCTAssertNil(LabelScores(labels: ["a"], scores: [1]).score(for: "zzz"))
    }

    func testAnUnavailableResultHasNoWinnerEvenWithScores() {
        XCTAssertNil(LabelScores(status: .unavailable, labels: ["a", "b"], scores: [0.9, 0.1]).topIndex)
        XCTAssertEqual(PromptRouteDecision.undecided, LabelScores.unavailable)
        XCTAssertFalse(LabeledSpans.unavailable.isEvaluated)
    }

    func testTheStatusIsSpelledOutOnTheWire() throws {
        let scores = String(decoding: try JSONEncoder().encode(LabelScores.unavailable), as: UTF8.self)
        XCTAssertTrue(scores.contains("\"status\":\"unavailable\""), scores)
        let spans = String(decoding: try JSONEncoder().encode(LabeledSpans(spans: [])), as: UTF8.self)
        XCTAssertTrue(spans.contains("\"status\":\"evaluated\""), spans)
    }

    func testMismatchedLabelsAndScoresAreRefusedAtTheWire() {
        let payload = Data(#"{"status":"evaluated","labels":["a","b"],"scores":[1.0]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LabelScores.self, from: payload))
    }

    /// The shapes a non-Swift peer sees: `Range<Int>` is a two-element array, a task is one keyed case
    /// with an object payload, and labels ride beside scores.
    func testWireShapesArePinned() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let span = LabeledSpan(label: "contact.email", score: 0.5, utf16Range: 6..<22, text: "laura@charite.de")
        XCTAssertEqual(
            String(decoding: try encoder.encode(LabeledSpans(spans: [span])), as: UTF8.self),
            #"{"spans":[{"label":"contact.email","score":0.5,"text":"laura@charite.de","utf16Range":[6,22]}],"status":"evaluated"}"#)
        XCTAssertEqual(
            String(decoding: try encoder.encode(LabelScores(labels: ["a", "b"], scores: [0.25, 0.75])), as: UTF8.self),
            #"{"labels":["a","b"],"scores":[0.25,0.75],"status":"evaluated"}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(ClassificationTask.sequence), as: UTF8.self), #"{"sequence":{}}"#)
        XCTAssertEqual(
            String(decoding: try encoder.encode(ClassificationTask.zeroShotToken(labels: ["r"], threshold: 0.5)), as: UTF8.self),
            #"{"zeroShotToken":{"labels":["r"],"threshold":0.5}}"#)
    }

    func testSpansLabeledComeBackInTextOrder() {
        let late = LabeledSpan(label: "x", score: 1, utf16Range: 10..<12, text: "cd")
        let early = LabeledSpan(label: "x", score: 1, utf16Range: 0..<2, text: "ab")
        let other = LabeledSpan(label: "y", score: 1, utf16Range: 5..<6, text: "q")
        XCTAssertEqual(LabeledSpans(spans: [late, other, early]).spans(labeled: "x"), [early, late])
    }

    func testAnUnrunnableTaskIsRefusedAtTheWire() {
        for payload in [
            #"{"zeroShotSequence":{"labels":[]}}"#,
            #"{"zeroShotSequence":{"labels":["a"," "]}}"#,
            #"{"zeroShotSequence":{"labels":["a","a"]}}"#,
            #"{"zeroShotToken":{"labels":["r"],"threshold":1.5}}"#,
            #"{"zeroShotToken":{"labels":["r"],"threshold":-0.1}}"#,
            #"{"token":{},"sequence":{}}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(ClassificationTask.self, from: Data(payload.utf8)), payload)
        }
        XCTAssertEqual(try JSONDecoder().decode(ClassificationTask.self, from: Data(#"{"token":{}}"#.utf8)), .token)
        XCTAssertEqual(
            try JSONDecoder().decode(ClassificationTask.self, from: Data(#"{"zeroShotToken":{"labels":["r"],"threshold":0.5}}"#.utf8)),
            .zeroShotToken(labels: ["r"], threshold: 0.5))
    }

    func testValidateNamesTheOffendingLabel() {
        XCTAssertThrowsError(try ClassificationTask.zeroShotSequence(labels: ["a", "b", "a"]).validate()) { error in
            XCTAssertEqual(error as? ClassificationTask.ValidationError, .duplicateLabel(index: 2))
        }
        XCTAssertThrowsError(try ClassificationTask.zeroShotToken(labels: ["a", ""], threshold: 0.5).validate()) { error in
            XCTAssertEqual(error as? ClassificationTask.ValidationError, .blankLabel(index: 1))
        }
        XCTAssertNoThrow(try ClassificationTask.sequence.validate())
        XCTAssertNoThrow(try ClassificationTask.zeroShotToken(labels: ["a"], threshold: 1).validate())
    }

    func testEachKindKnowsItsResultShape() {
        XCTAssertFalse(ClassificationTask.Kind.sequence.yieldsSpans)
        XCTAssertFalse(ClassificationTask.Kind.zeroShotSequence.yieldsSpans)
        XCTAssertTrue(ClassificationTask.Kind.token.yieldsSpans)
        XCTAssertTrue(ClassificationTask.Kind.zeroShotToken.yieldsSpans)
    }

    func testResultsRoundTripThroughJSON() throws {
        let scores = LabelScores(labels: ["a", "b"], scores: [0.25, 0.75])
        XCTAssertEqual(try JSONDecoder().decode(LabelScores.self, from: try JSONEncoder().encode(scores)), scores)
        let spans = LabeledSpans(spans: [LabeledSpan(label: "contact.email", score: 0.9, utf16Range: 6..<22, text: "laura@charite.de")])
        XCTAssertEqual(try JSONDecoder().decode(LabeledSpans.self, from: try JSONEncoder().encode(spans)), spans)
    }

    func testSpanOffsetsAreUTF16UnitsOfTheSourceText() throws {
        // A non-BMP scalar (🙂) is two UTF-16 units and one Character: offsets must count units.
        let text = "🙂 laura@charite.de"
        let span = LabeledSpan(label: "contact.email", score: 0.9, utf16Range: 3..<19, text: "laura@charite.de")
        let range = try XCTUnwrap(span.range(in: text))
        XCTAssertEqual(String(text[range]), span.text)

        let combining = "e\u{301} x"   // e + combining acute, then x at UTF-16 offset 3
        let x = LabeledSpan(label: "l", score: 1, utf16Range: 3..<4, text: "x")
        XCTAssertEqual(String(combining[try XCTUnwrap(x.range(in: combining))]), "x")
    }

    func testOutOfBoundsOffsetsYieldNoRange() {
        XCTAssertNil(LabeledSpan(label: "l", score: 1, utf16Range: 0..<10, text: "").range(in: "short"))
        XCTAssertNil(LabeledSpan(label: "l", score: 1, utf16Range: -1..<2, text: "").range(in: "short"))
    }

    func testPinDescriptionShowsEveryConstraintMatchingHonours() {
        XCTAssertNil(ModelSpecDescriptor().pinDescription)
        XCTAssertEqual(ModelSpecDescriptor(sourceID: "acme/pii").pinDescription, "acme/pii")
        XCTAssertEqual(ModelSpecDescriptor(sourceID: "acme/pii", revision: "0123456789").pinDescription, "acme/pii @ 01234567")
        XCTAssertEqual(ModelSpecDescriptor(revision: "0123456789").pinDescription, "@ 01234567")
        XCTAssertEqual(
            ModelSpecDescriptor(sourceID: "acme/pii", additionalFiles: ["head.safetensors"]).pinDescription,
            "acme/pii +head.safetensors")
    }

    // MARK: - Redaction

    private func span(_ label: String, _ range: Range<Int>) -> LabeledSpan {
        LabeledSpan(label: label, score: 0.9, utf16Range: range, text: "")
    }

    func testRedactionReplacesEachSpanFromTheEnd() {
        let text = "Email laura@charite.de or call Laura."
        let result = LabeledSpans(spans: [span("email", 6..<22), span("name", 31..<36)])
        XCTAssertEqual(result.redacting(text) { "[\($0.joined(separator: "+"))]" }, "Email [email] or call [name].")
    }

    func testOverlappingSpansAreMergedSoNoPartSurvives() {
        let text = "Hi Rene\u{301}Dupont!"
        let result = LabeledSpans(spans: [span("first_name", 3..<8), span("last_name", 6..<14)])
        XCTAssertEqual(result.redacting(text) { "[\($0.joined(separator: "+"))]" }, "Hi [first_name+last_name]!")
    }

    func testTouchingSpansStaySeparate() {
        let text = "ab"
        let result = LabeledSpans(spans: [span("x", 1..<2), span("y", 0..<1)])
        XCTAssertEqual(result.redacting(text) { "<\($0[0])>" }, "<y><x>")
    }

    func testOffsetsOutsideTheTextAreIgnored() {
        let result = LabeledSpans(spans: [span("x", 3..<9), span("y", 0..<1)])
        XCTAssertEqual(result.redacting("abc") { _ in "_" }, "_bc")
    }

    func testRedactionLeavesACleanTextAlone() {
        XCTAssertEqual(LabeledSpans(spans: []).redacting("abc") { _ in "_" }, "abc")
    }
}
