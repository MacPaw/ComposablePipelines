//
//  BatchSummaryPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// Map-reduce over a collection: summarize each document into a running notes slot, then
/// synthesize one digest from the accumulated notes.
///
/// Demonstrates:
/// - `ForEach` — data-driven fan-out. The body is unrolled once per element **at lowering**,
///   so the number of steps follows the input collection (contrast `ContentWriterPipeline`,
///   whose fan-out width is fixed in source).
/// - Accumulation across iterations through a shared `@State` slot read at **runtime** with
///   `.get()`: each iteration sees the value the previous one committed.
/// - A final **reduce** step over the accumulated state.
struct BatchSummaryPipeline: Pipeline {
    typealias Output = String

    let documents: [String]

    /// Running notes — each iteration reads the prior value and appends its summary.
    @State var notes: String = ""
    @State var digest: String = ""

    var body: some Pipeline {
        // MAP: one summary step per document, threading `notes` through each iteration.
        ForEach(documents) { document in
            Model<String>("""
                Summarize the document in one line and append it to the running notes. \
                Document:
                \(document)
                """)
                .input { $notes }
                .assign(to: $notes)
        }

        // REDUCE: collapse the accumulated notes into a short digest.
        Model<String>("Write a two-sentence digest of these notes.")
            .input { $notes }
            .assign(to: $digest)
    }
}
