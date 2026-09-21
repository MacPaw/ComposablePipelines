//
//  CustomerSupportPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// Routes customer messages by intent, with specialized handling per category.
/// Demonstrates: switch branching, pipeline composition (reuses DocumentSummaryPipeline's pattern),
/// parallel enrichment, state-driven control flow.
struct CustomerSupportPipeline: Pipeline {
    typealias Output = String

    @State var message: String
    @State var intent: String = ""
    @State var sentiment: String = ""
    @State var context: String = ""
    @State var reply: String = ""

    var body: some Pipeline {
        Guardrail(
            message,
            rules: [.pii],
            allowed: {
                // Parallel enrichment — intent + sentiment will resolve independently
                Model<String>("Classify customer intent: billing, technical, feedback, or general")
                    .input { $message }
                    .assign(to: $intent)

                Model<String>("Analyze customer sentiment in one word: positive, neutral, frustrated, angry")
                    .input { $message }
                    .assign(to: $sentiment)
                switch intent {
                case "billing":
                    Model<String>("Look up relevant billing policies and recent account activity")
                        .input { $message }
                        .assign(to: $context)
                    // Prompt bakes bare `sentiment` (@State) → closure form captures that read.
                    $reply.set {
                        Model<String>("Draft a billing support response. Be empathetic if sentiment is \(sentiment)")
                            .input { $context }
                    }

                case "technical":
                    Model<String>("Search knowledge base for relevant troubleshooting steps")
                        .input { $message }
                        .assign(to: $context)
                    Model<String>("Write step-by-step technical support instructions")
                        .input { $context }
                        .assign(to: $reply)

                case "feedback":
                    Model<String>("Thank the customer for their feedback and acknowledge their points")
                        .input { $message }
                        .assign(to: $reply)

                case "general":
                    Model<String>("Provide a helpful general response")
                        .input { $message }
                        .assign(to: $reply)
                default:
                    $reply.set("I'm not sure how to help with \(intent).")
                }
            },
            blocked: {
                Just(value: "I can't help with that — it conflicts with the configured safety policy.")
            }
        )
    }
}
