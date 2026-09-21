//
//  ContentWriterPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// Generates content through a draft → parallel critique → rewrite cycle.
/// Demonstrates: parallel fan-out for independent analysis, merging results,
/// multi-step refinement.
struct ContentWriterPipeline: Pipeline {
    typealias Output = String

    @State var topic: String
    @State var tone: String = "professional"
    @State var draft: String = ""
    @State var grammarNotes: String = ""
    @State var styleNotes: String = ""
    @State var factNotes: String = ""
    @State var finalDraft: String = ""

    var body: some Pipeline {
        Guardrail(
            topic,
            rules: [.pii],
            allowed: {
                // Prompt bakes bare `tone` (@State) → closure form captures that read.
                $draft.set {
                    Model<String>("Write a \(tone) article about the given topic. 3-4 paragraphs.")
                        .input { $topic }
                }

                $tone.set("toxic")

                // Parallel critique — three independent reviewers
                Model<String>("Review for grammar and clarity issues only. Be concise.")
                    .input { $draft }
                    .assign(to: $grammarNotes)
                $styleNotes.set {
                    Model<String>("Review tone and style. Does it match '\(tone)'? Be concise.")
                        .input { $draft }
                }
                Model<String>("Flag any unsupported claims or factual concerns. Be concise.")
                    .input { $draft }
                    .assign(to: $factNotes)

                // Rewrite incorporating all feedback — bakes bare notes (@State), so closure form.
                $finalDraft.set {
                    Model<String> {
                        "Rewrite this draft incorporating the following feedback:"
                        "Grammar: \(grammarNotes)"
                        "Style: \(styleNotes)"
                        "Facts: \(factNotes)"
                    }
                    .input { $draft }
                }
            },
            blocked: {
                Just(value: "I can't help with that — it conflicts with the configured safety policy.")
            }
        )
    }
}
