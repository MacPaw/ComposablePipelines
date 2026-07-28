//
//  DocumentSummaryPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// Multi-stage document summarization.
/// Demonstrates: sequential state flow, Summarize, Group.
struct DocumentSummaryPipeline: Pipeline {
    typealias Output = String

    let document: String

    @State var keyPoints: String = ""
    @State var draft: String = ""
    @State var summary: String = ""

    var body: some Pipeline {
        Model<String>("Extract the 5 most important points from this document")
            .message(document)
            .assign(to: $keyPoints)

        Model<String>("Write a comprehensive summary based on these key points")
            .input { $keyPoints }
            .assign(to: $draft)

        Group {
            Summarize(text: $draft, maxTokens: 512).assign(to: $summary)
        }
    }
}
