//
//  DelegateResearchPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// Delegate-of-subagents fan-out: decompose a question into independent angles, dispatch a **delegate** of
/// short-lived subagents to answer each one agent-side (bounded by a spawn budget, sharing one model),
/// then synthesize a single answer from their replies.
///
/// Demonstrates:
/// - `Delegate(tasks:taskInput:budget:)` — the declarative agent-side fan-out. Each subagent runs the
///   trailing pipeline in its own isolated scope, with its task seeded into `taskInput`.
/// - Gathering the delegate's `[String?]` output into a slot (`nil` marks a budget-refused subagent).
/// - A final reduce step that synthesizes one answer from the gathered replies.
struct DelegateResearchPipeline: Pipeline {
    typealias Output = String

    let question: String

    /// The angles to fan out over, seeded from the question.
    @State var angles: [String] = []
    /// Seeded per subagent by the delegate — the child reads it with `.get()`.
    @State var angle: String = ""
    /// The gathered per-subagent replies.
    @State var replies: [String?] = []
    @State var answer: String = ""

    var body: some Pipeline {
        $angles.set([
            "Summarize in one sentence: \(question)",
            "State the biggest risk or caveat about: \(question)",
            "Give the strongest counterpoint to: \(question)",
            "Suggest one concrete next step for: \(question)",
        ])

        // FAN OUT: a delegate of subagents, each answering one angle against the shared model.
        $replies.set {
            Delegate(tasks: $angles, taskInput: $angle, budget: .init(total: 8, leafReserve: 1)) {
                Model<String>()
                    .systemPrompt("Answer the sub-question in one concise sentence.")
                    .input { $angle.get() }
            }
        }

        // REDUCE: synthesize a single coherent answer from the delegate's replies.
        $answer.set {
            Model<String>()
                .systemPrompt("Synthesize one coherent answer from these independent findings.")
                .input { $replies.get() }
        }

        $answer.get()
    }
}
