//
//  CodeReviewPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// Cost-aware code review: triage the diff with a small, fast, on-device model; trivial diffs
/// exit immediately, anything else escalates to a heavyweight reasoning model.
///
/// Demonstrates:
/// - `requirements:` — request a model by capability/cost rather than by name. Triage prefers a
///   quick, local model; the deep review asks for a reasoning model. *Which* model satisfies the
///   request is the executor's job; the pipeline only states intent.
/// - Branching on a produced value: the `if` reads `verdict`, so after the triage step commits,
///   reactive recompilation re-evaluates the branch against the model's actual verdict.
/// - `Self.return` — short-circuit with a value, skipping the expensive path entirely.
struct CodeReviewPipeline: Pipeline {
    typealias Output = String

    @State var diff: String
    @State var verdict: String = ""
    @State var review: String = ""

    var body: some Pipeline {
        // Cheap triage on a quick on-device model.
        Model<String>(
            "Triage this diff. Reply with exactly 'trivial' or 'needs-review'.",
            requirements: ModelSelectionRequirements(traits: [.quick, .localOnly])
        )
        .input { $diff }
        .assign(to: $verdict)

        // Trivial diffs never reach the expensive model.
        if verdict == "trivial" {
            Self.return("LGTM — trivial change, no deep review needed.")
        }

        // Escalate: thorough review on a reasoning model.
        Model<String>(
            "Perform a thorough code review of this diff and list concerns.",
            requirements: ModelSelectionRequirements(traits: [.reasoning])
        )
        .input { $diff }
        .assign(to: $review)
        $review
    }
}
