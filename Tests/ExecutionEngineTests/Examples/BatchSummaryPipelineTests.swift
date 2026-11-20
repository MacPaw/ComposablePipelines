//
//  BatchSummaryPipelineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
@testable import Examples
@testable import ExecutionEngine

/// End-to-end execution of ``BatchSummaryPipeline``: the `ForEach` map step must run once per
/// document, accumulate through the `notes` slot, and reduce into `digest` last.
final class BatchSummaryPipelineTests: XCTestCase {

    private let documents = ["alpha", "beta", "gamma"]

    /// Append the current document (extracted from the instructions) to the running notes
    /// (the model `input`). The pipeline — not the script — owns the threading: the executor
    /// only ever sees `input == notes-so-far`.
    private func appendingExecutor() -> ScriptedExecutor {
        ScriptedExecutor { call in
            if call.instructions.contains("two-sentence digest") {
                return ScriptedExecutor.string("DIGEST(\(call.input))")
            }
            let document = call.instructions
                .components(separatedBy: "Document:").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let next = call.input.isEmpty ? document : "\(call.input) | \(document)"
            return ScriptedExecutor.string(next)
        }
    }

    // MARK: - Mid-execution state

    func testNotesSlot_accumulatesOneSummaryPerDocumentInOrder() async throws {
        let pipeline = BatchSummaryPipeline(documents: documents)
        let (_, events) = try await PipelineRun.runOnce(pipeline, executor: appendingExecutor())

        XCTAssertEqual(
            events.slotHistoryStrings(pipeline.$notes.id),
            ["alpha", "alpha | beta", "alpha | beta | gamma"],
            "Each iteration must read the prior notes and append exactly its own document."
        )
    }

    // MARK: - Step-over-step ordering

    func testMapRunsOncePerDocument_thenReduceLast() async throws {
        let pipeline = BatchSummaryPipeline(documents: documents)
        let (_, events) = try await PipelineRun.runOnce(pipeline, executor: appendingExecutor())

        let notesWrites = events.enumerated().compactMap { index, event -> Int? in
            if case .stateUpdated(let update) = event, update.slotID == pipeline.$notes.id { return index }
            return nil
        }
        let digestWrites = events.enumerated().compactMap { index, event -> Int? in
            if case .stateUpdated(let update) = event, update.slotID == pipeline.$digest.id { return index }
            return nil
        }

        XCTAssertEqual(notesWrites.count, documents.count, "One map write per document.")
        XCTAssertEqual(digestWrites.count, 1, "Exactly one reduce write.")
        XCTAssertLessThan(
            try XCTUnwrap(notesWrites.last),
            try XCTUnwrap(digestWrites.first),
            "The reduce must write `digest` only after the final map write to `notes`."
        )
    }

    // MARK: - Result

    func testResult_isDigestOverFullyAccumulatedNotes() async throws {
        let pipeline = BatchSummaryPipeline(documents: documents)
        let (result, events) = try await PipelineRun.runOnce(pipeline, executor: appendingExecutor())

        let digest = try XCTUnwrap(events.lastValue(forSlot: pipeline.$digest.id))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: digest), "DIGEST(alpha | beta | gamma)")
        XCTAssertEqual(result, digest, "Pipeline output is the final reduce value.")
    }
}
