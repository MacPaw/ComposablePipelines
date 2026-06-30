//
//  ContentModerationPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// Screens user input for policy violations, then classifies severity.
/// Demonstrates: guardrails as gates, if/else branching on state, parallel enrichment.
struct ContentModerationPipeline: Pipeline {
    typealias Output = String

    @State var input: String
    @State var severity: String = ""
    @State var category: String = ""
    @State var explanation: String = ""

    var body: some Pipeline {
        Guardrail(
            input,
            rules: [.politics, .pii],
            allowed: {
                $severity.set {
                    Model<String>().systemPrompt("Classify content severity...").input { $input.get() }
                }

                if severity == "safe" {
                    $explanation.set("Content is safe. No action needed.")
                } else {
                    $category.set {
                        Model<String>().systemPrompt("Categorize the policy violation...").input { $input.get() }
                    }
                    $explanation.set {
                        Model<String>().systemPrompt("Write a brief moderation ...: \(severity)").input { $input.get() }
                    }
                }
            },
            blocked: {
                Just(value: "I can't help with that — it conflicts with the configured safety policy.")
            }
        )
    }
}
