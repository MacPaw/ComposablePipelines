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
        Guardrail(rules: [.politics, .pii])

        $severity.set {
            Model<String, String>(instructions: "Classify content severity...", input: $input.get())
        }

        if severity == "safe" {
            $explanation.set("Content is safe. No action needed.")
        } else {
            $category.set {
                Model<String, String>(instructions: "Categorize the policy violation...", input: $input.get())
            }
            $explanation.set {
                Model<String, String>(instructions: "Write a brief moderation ...: \(severity)", input: $input.get())
            }
        }
    }
}
