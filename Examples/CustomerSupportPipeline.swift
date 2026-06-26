//
//  CustomerSupportPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
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
        Guardrail(rules: [.pii])

        // Parallel enrichment — intent + sentiment will resolve independently
        $intent.set {
            Model<String, String>(
                instructions: "Classify customer intent: billing, technical, feedback, or general",
                input: $message.get()
            )
        }

        $sentiment.set {
            Model<String, String>(
                instructions: "Analyze customer sentiment in one word: positive, neutral, frustrated, angry",
                input: $message.get()
            )
        }
        switch intent {
        case "billing":
            $context.set {
                Model<String, String>(
                    instructions: "Look up relevant billing policies and recent account activity",
                    input: $message.get()
                )
            }
            $reply.set {
                Model<String, String>(
                    instructions: "Draft a billing support response. Be empathetic if sentiment is \(sentiment)",
                    input: $context.get()
                )
            }

        case "technical":
            $context.set {
                Model<String, String>(
                    instructions: "Search knowledge base for relevant troubleshooting steps",
                    input: $message.get()
                )
            }
            $reply.set {
                Model<String, String>(
                    instructions: "Write step-by-step technical support instructions",
                    input: $context.get()
                )
            }

        case "feedback":
            $reply.set {
                Model<String, String>(
                    instructions: "Thank the customer for their feedback and acknowledge their points",
                    input: $message.get()
                )
            }

        case "general":
            $reply.set {
                Model<String, String>(
                    instructions: "Provide a helpful general response",
                    input: $message.get()
                )
            }
        default:
            $reply.set("I'm not sure how to help with \(intent).")
        }
    }
}
