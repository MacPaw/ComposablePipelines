//
//  RoutingPipelineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL

final class RoutingPipelineTests: XCTestCase {
    func testPromptRouterLowersToAZeroShotSequenceClassification() {
        let lanes = ["answer directly", "needs a tool"]
        let graph = Classify("Find the release notes", using: PromptRouter(lanes: lanes)).pipelineGraph

        guard case let .leaf(.classify(text, task, spec)) = graph else {
            XCTFail("expected classify leaf")
            return
        }
        XCTAssertEqual(task, .zeroShotSequence(labels: lanes), "lane order is the contract for reading scores back")
        XCTAssertNil(spec, "a router names its model family by kind, not by checkpoint")

        guard case let .leaf(.just(valueTypeName, jsonUTF8)) = text else {
            XCTFail("expected constant router query")
            return
        }
        XCTAssertEqual(valueTypeName, "String")
        XCTAssertEqual(jsonUTF8, "\"Find the release notes\"")
    }

    func testEveryKindHasAClassifier() {
        let pin = ModelSpecDescriptor(sourceID: "acme/encoder", revision: "abc")
        let cases: [(any Classifier, ClassificationTask)] = [
            (SequenceClassifier(spec: pin), .sequence),
            (ZeroShotSequenceClassifier(labels: ["a", "b"], spec: pin), .zeroShotSequence(labels: ["a", "b"])),
            (TokenClassifier(spec: pin), .token),
            (ZeroShotTokenClassifier(labels: ["r"], threshold: 0.7, spec: pin), .zeroShotToken(labels: ["r"], threshold: 0.7)),
        ]
        for (classifier, task) in cases {
            XCTAssertEqual(classifier.task, task)
            XCTAssertEqual(classifier.spec, pin, "the pin reaches the leaf from every classifier")
        }
        XCTAssertEqual(ClassificationTask.Kind.allCases.count, cases.count, "the matrix is covered")
    }

    func testNamedClassifiersAreTheGenericTasksSpelledForTheirUse() {
        let lanes = ["answer directly", "needs a tool"]
        XCTAssertEqual(PromptRouter(lanes: lanes).task, ZeroShotSequenceClassifier(labels: lanes).task)
        XCTAssertEqual(PIIDetector().task, TokenClassifier().task)
        let rules = ["Flag competitor mentions."]
        XCTAssertEqual(PolicyLinter(rules: rules, threshold: 0.6).task, ZeroShotTokenClassifier(labels: rules, threshold: 0.6).task)
        XCTAssertEqual(PolicyLinter(rules: rules).task, .zeroShotToken(labels: rules, threshold: 0.5), "the model card's default threshold")
    }

    func testBothVerbsLowerToTheSameLeaf() {
        let text = "Email laura@charite.de"
        guard case let .leaf(.classify(_, detected, _)) = Detect(text, using: PIIDetector()).pipelineGraph,
              case let .leaf(.classify(_, scored, _)) = Classify(text, using: PromptRouter(lanes: ["a"])).pipelineGraph
        else { return XCTFail("expected classify leaves") }
        XCTAssertEqual(detected, .token)
        XCTAssertEqual(scored, .zeroShotSequence(labels: ["a"]))
        XCTAssertEqual(
            Detect(using: PolicyLinter(rules: ["r"])) { Just(value: text) }.pipelineGraph,
            Detect(text, using: PolicyLinter(rules: ["r"])).pipelineGraph,
            "the literal and builder spellings lower identically")
    }

    func testPseudoSwiftNamesTheVerbAndThePin() {
        let pin = ModelSpecDescriptor(sourceID: "acme/pii", revision: "0123456789abcdef")
        XCTAssertTrue(
            Detect("t", using: PIIDetector(spec: pin)).pipelineGraph.pseudoSwiftDescription
                .hasPrefix("Detect(token, spec: \"acme/pii @ 01234567\") {"))
        XCTAssertTrue(
            Classify("t", using: PromptRouter(lanes: ["a", "b"])).pipelineGraph.pseudoSwiftDescription
                .hasPrefix("Classify(zeroShotSequence(labels: 2)) {"))
        XCTAssertTrue(
            Detect("t", using: PolicyLinter(rules: ["r"], threshold: 0.3, spec: ModelSpecDescriptor())).pipelineGraph.pseudoSwiftDescription
                .hasPrefix("Detect(zeroShotToken(labels: 1, threshold: 0.3)) {"),
            "an empty spec pins nothing and is not shown")
    }

    func testClassifyLeafRoundTripsThroughJSON() throws {
        for graph in [
            Classify("hello", using: SequenceClassifier()).pipelineGraph,
            Classify("hello", using: ZeroShotSequenceClassifier(labels: ["a", "b"])).pipelineGraph,
            Detect("text", using: TokenClassifier()).pipelineGraph,
            Detect("text", using: ZeroShotTokenClassifier(labels: ["r"], threshold: 0.6)).pipelineGraph,
        ] {
            XCTAssertEqual(try PipelineGraph.decode(from: try JSONEncoder().encode(graph)), graph)
        }
    }

    func testDAGPlannerLowersToDAGPlanLeafWithToolsAndHints() {
        let tool = ToolDescriptor(
            name: "search_demo_knowledge",
            description: "Searches demo knowledge.",
            inputSchema: .object(properties: ["query": .string], required: ["query"])
        )

        let graph = DAGPlanner(
            "Find and summarize release notes",
            tools: [tool],
            hints: ["Prefer a small DAG."]
        )
        .pipelineGraph

        guard case let .leaf(.dagPlan(query, tools, hints)) = graph else {
            XCTFail("expected dagPlan leaf")
            return
        }
        XCTAssertEqual(tools, [tool])
        XCTAssertEqual(hints, ["Prefer a small DAG."])

        guard case let .leaf(.just(valueTypeName, jsonUTF8)) = query else {
            XCTFail("expected constant DAG query")
            return
        }
        XCTAssertEqual(valueTypeName, "String")
        XCTAssertEqual(jsonUTF8, "\"Find and summarize release notes\"")
    }
}
