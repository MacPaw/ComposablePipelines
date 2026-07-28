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
                Model<String>("Classify content severity...").input { $input }.assign(to: $severity)

                if severity == "safe" {
                    $explanation.set("Content is safe. No action needed.")
                } else {
                    Model<String>("Categorize the policy violation...").input { $input }.assign(to: $category)
                    // Prompt bakes bare `severity` (@State) → closure form captures that read.
                    $explanation.set {
                        Model<String>("Write a brief moderation ...: \(severity)").input { $input }
                    }
                }
            },
            blocked: {
                Just(value: "I can't help with that — it conflicts with the configured safety policy.")
            }
        )
    }
}
