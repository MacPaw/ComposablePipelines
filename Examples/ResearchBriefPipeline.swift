//
//  ResearchBriefPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineDSL

/// Showcase pipeline for the Tier-1 authoring sugar: it drafts a research brief from note
/// chunks, loops a review/revise pass until approved, counts words on the host, and condenses
/// if the draft runs long.
///
/// Every spelling here lowers to the same graph as its verbose form — the sugar is purely at
/// the call site:
/// - `Model<T>("prompt")` unlabeled system prompt, and `Model(_, generating:)` to pin the
///   output type at the call site
/// - `Model<T> { "line"; "line" }` multi-line prompt via `@InstructionsBuilder`
/// - `pipeline.assign(to: $slot)` producer-first writes
/// - `ForEach(chunks) { … }` without the `in:` label
/// - `While(!review.approved) { … }` autoclosure condition
/// - `Run($a, $b) { … }` multi-binding host task, and `$slot.map { … }` transforms
/// - `Barrier { GateGuardrail(.politics, .pii) { … } }` named grouping + variadic gate
/// - a bare `$slot` as the final line == `$slot.get()`
struct ResearchBriefPipeline: Pipeline {
    typealias Output = String

    let question: String
    let tone: String
    let chunks: [String]

    @State var notes = ""
    @State var draft = ""
    @State var review = Review(approved: false, feedback: "")
    @State var wordCount = 0

    var body: some Pipeline {
        // Named barrier instead of Group(gate: true); variadic gate instead of rules: [ ... ].
        Barrier {
            GateGuardrail(.politics, .pii) { Just(value: question) }
        }

        // Unlabeled ForEach; unlabeled Model prompt; producer-first assign.
        ForEach(chunks) { chunk in
            Model<String>("Extract facts relevant to: \(question)")
                .input(chunk)
                .assign(to: $notes)
        }

        // Multi-line prompt via @InstructionsBuilder.
        Model<String> {
            "Write a research brief from these notes."
            "Cite every fact you use."
            "Match this tone: \(tone)."
        }
        .input { $notes }
        .assign(to: $draft)

        // Autoclosure While reading structured @State; generating: pins the output type.
        While(!review.approved) {
            Model("Review the brief. Approve, or give concrete feedback.", generating: Review.self)
                .input { $draft }
                .assign(to: $review)

            if !review.approved {
                // Prompt bakes bare `review.feedback` (@State) → closure form captures that read.
                $draft.set {
                    Model<String>("Revise the brief per this feedback: \(review.feedback)")
                        .input { $draft }
                }
            }
        }

        // Host-side transform via map; producer-first assign.
        $draft.map { $0.split(whereSeparator: \.isWhitespace).count }
            .assign(to: $wordCount)

        // Multi-binding Run: both slots arrive together (lowers input to a `combine` leaf).
        if wordCount > 800 {
            Run($draft, $wordCount) { draft, count in
                "[\(count) words] " + draft
            }
            .assign(to: $draft)
        }

        // Bare binding as the final line == $draft.get().
        $draft
    }
}

/// Structured review verdict — replaces sniffing a magic "APPROVED" string.
struct Review: ModelOutput {
    let approved: Bool
    let feedback: String
}
