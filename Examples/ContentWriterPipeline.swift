//
//  ContentWriterPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
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
                $draft.set {
                    Model<String>()
                        .systemPrompt("Write a \(tone) article about the given topic. 3-4 paragraphs.")
                        .input { $topic.get() }
                }

                $tone.set("toxic")

                // Parallel critique — three independent reviewers
                $grammarNotes.set {
                    Model<String>()
                        .systemPrompt("Review for grammar and clarity issues only. Be concise.")
                        .input { $draft.get() }
                }
                $styleNotes.set {
                    Model<String>()
                        .systemPrompt("Review tone and style. Does it match '\(tone)'? Be concise.")
                        .input { $draft.get() }
                }
                $factNotes.set {
                    Model<String>()
                        .systemPrompt("Flag any unsupported claims or factual concerns. Be concise.")
                        .input { $draft.get() }
                }

                // Rewrite incorporating all feedback
                $finalDraft.set {
                    Model<String>()
                        .systemPrompt("""
                            Rewrite this draft incorporating the following feedback:\n\
                            Grammar: \(grammarNotes)\n\
                            Style: \(styleNotes)\n\
                            Facts: \(factNotes)
                            """)
                        .input { $draft.get() }
                }
            },
            blocked: {
                Just(value: "I can't help with that — it conflicts with the configured safety policy.")
            }
        )
    }
}
