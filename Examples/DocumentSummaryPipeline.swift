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
        $keyPoints.set {
            Model<String>()
                .systemPrompt("Extract the 5 most important points from this document")
                .message(document)
        }

        $draft.set {
            Model<String>()
                .systemPrompt("Write a comprehensive summary based on these key points")
                .input { $keyPoints.get() }
        }

        Group {
            $summary.set { Summarize(text: $draft, maxTokens: 512) }
        }
    }
}
