//
//  ContentModerationPipelineDeterminismTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineCompiler
import PipelineAST
import PipelineDSL
@_spi(Internals) @testable import ExecutionEngine

final class ContentModerationPipelineDeterminismTests: XCTestCase {

    private final class LockedEvents: @unchecked Sendable {
        private let lock = Lock()
        private var events: [ExecutionEvent] = []

        func append(_ event: ExecutionEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [ExecutionEvent] {
            lock.lock()
            let copy = events
            lock.unlock()
            return copy
        }
    }

    /// Mirrors ``ContentModerationPipeline`` in `PipelineDSLPlayground` so package tests
    /// can exercise the same DSL shape without importing the Xcode target.
    private struct ContentModerationLikePipeline: Pipeline {
        typealias Output = String

        @State var input: String
        @State var severity: String = ""
        @State var category: String = ""
        @State var explanation: String = ""

        init(input: String) {
            _input = State(wrappedValue: input)
            _severity = State(wrappedValue: "")
            _category = State(wrappedValue: "")
            _explanation = State(wrappedValue: "")
        }

        var body: some Pipeline {
            $severity.set {
                Model<String>().systemPrompt("Classify content severity...").message(input)
            }

            if severity == "safe" {
                $explanation.set("Content is safe. No action needed.")
            } else {
                $category.set {
                    Model<String>().systemPrompt("Categorize the policy violation...").message(input)
                }
                $explanation.set {
                    Model<String>().systemPrompt("Write a brief moderation ...: \(severity)").message(input)
                }
            }
        }
    }

    private let compiler = PipelineCompiler(optimizations: [.parallelize])
    private let engine = PipelineWalker(executor: MockExecutor())

    private let iterationCount = 100

    private func encodeJSONString(_ value: String) throws -> ExecutionValue {
        try JSONEncoder().encode(value)
    }

    private func decodeJSONString(_ data: ExecutionValue) throws -> String {
        try JSONDecoder().decode(String.self, from: data)
    }

    private func lastStateValue(for slotID: UUID, in events: [ExecutionEvent]) -> ExecutionValue? {
        events.reversed().lazy.compactMap { event -> ExecutionValue? in
            if case .stateUpdated(let u) = event, u.slotID == slotID { return u.value }
            return nil
        }.first
    }

    /// With ``ResourceHeap.mock`` there is no ``ModelExecutionResource``; every model call yields
    /// ``Data.emptyJSON`` (JSON `""`), so `severity == "safe"` is false and the
    /// `else` branch runs; the explanation model is the semantic final write.
    private let expectedExplanationBytes = Data.emptyJSON

    /// ``GraphWalker`` returns the last non-nil branch result for a `.parallel` node
    /// (`branchResults.reversed().compactMap { $0 }.first ?? Data()`). The explanation model
    /// is the last branch, so the top-level run return equals ``Data.emptyJSON`` (JSON `""`).
    /// Assert the explanation **slot** for end-to-end semantics.
    private let expectedTopLevelRunReturn = Data.emptyJSON

    func testContentModerationLikePipeline_mockHeap_hundredRuns_slotAndReturnValueDeterministic() async throws {
        let query = "How do I hack into my neighbor's WiFi?"

        var baselineExplanation: ExecutionValue?
        var baselineReturn: ExecutionValue?

        for _ in 0..<iterationCount {
            let pipeline = ContentModerationLikePipeline(input: query)
            let graph = compiler.compile(pipeline.pipelineGraph)
            let sink = LockedEvents()
            let result = try await engine.run(
                graph: graph,
                initialSlots: [pipeline.$input.id: try encodeJSONString(query)],
                observingExecution: { sink.append($0) }
            )

            let events = sink.snapshot()
            let explanation = try XCTUnwrap(lastStateValue(for: pipeline.$explanation.id, in: events))

            if baselineExplanation == nil {
                baselineExplanation = explanation
                baselineReturn = result
            } else {
                XCTAssertEqual(
                    explanation,
                    baselineExplanation,
                    "Last write to the explanation slot must be identical across runs."
                )
                XCTAssertEqual(
                    result,
                    baselineReturn,
                    "Top-level run return must be identical across runs (parallel tail is empty `Data()`)."
                )
            }

            XCTAssertEqual(
                explanation,
                expectedExplanationBytes,
                "Mock models produce JSON empty string in the explanation slot."
            )
            XCTAssertEqual(try decodeJSONString(explanation), "")
            XCTAssertEqual(result, expectedTopLevelRunReturn)
        }
    }
}
