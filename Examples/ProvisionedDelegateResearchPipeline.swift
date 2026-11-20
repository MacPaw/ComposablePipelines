//
//  ProvisionedDelegateResearchPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// The **atomic per-subagent context** pattern: the parent provisions a tailored *environment* for
/// each subagent, depending on that subagent's subtask, and hands it over as a rich task value. Each
/// delegate runs fully sandboxed (`inherit: .isolated` — no live providers) and sees **only** its own
/// slice, so its context is atomic by construction.
///
/// This is the "SwiftUI list building" intuition applied at the **parent**: `subQuestions.map { … }`
/// configures one `SubagentEnvironment` per subtask — the conditional per-item modifiers live here,
/// where the runtime data and the parent's resources (here a corpus) meet. The child is a pure
/// prototype that just reads its provisioned environment. It needs **no engine change**: `Delegate`'s
/// task type is generic, so the "task" carries the whole environment.
///
/// The same pattern works with `DelegateSelf` (a self-cloning agent whose delegates are each provisioned):
/// only the task type changes.
struct ProvisionedDelegateResearchPipeline: Pipeline {
    typealias Output = String

    let question: String
    /// The parent's knowledge; each subagent is provisioned only the slice relevant to its subtask.
    let corpus: [String]

    @State var subQuestions: [String] = []
    /// One provisioned environment per subtask — built by the parent (see step 2).
    @State var environments: [SubagentEnvironment] = []
    /// Seeded per delegate: the environment the parent provisioned for this subagent.
    @State var environment: SubagentEnvironment = .empty
    @State var answers: [String?] = []
    @State var answer: String = ""

    var body: some Pipeline {
        // 1. Decompose the question into independent sub-questions.
        $subQuestions.set(Self.decompose(question))

        // 2. PROVISION: for each sub-question, select the relevant corpus slice and package it as that
        //    subagent's environment. This is the per-child, subtask-dependent configuration — the
        //    parent applies it here (it has both the runtime subtasks and the corpus).
        $environments.set {
            Run(input: $subQuestions) { [corpus] subs in
                subs.map { SubagentEnvironment(subQuestion: $0, documents: Self.select($0, from: corpus)) }
            }
        }

        // 3. Fan out. Each delegate is seeded with its own environment and runs isolated — it can reach
        //    neither the parent's providers nor the rest of the corpus, only what it was provisioned.
        $answers.set {
            Delegate(tasks: $environments, taskInput: $environment, budget: .init(total: 8), inherit: .isolated) {
                // The prototype reads its provisioned environment as the model input (no client action,
                // so no provider is needed — the environment is pure data).
                Model<String>()
                    .systemPrompt("Answer the sub-question using only the provided documents.")
                    .input { $environment.get() }
            }
        }

        // 4. Combine the subagents' answers into one.
        $answer.set {
            Model<String>()
                .systemPrompt("Combine these findings into one coherent answer.")
                .input { $answers.get() }
        }

        $answer.get()
    }

    /// Split the question into sub-questions on `;` (deterministic, so the example runs reproducibly).
    /// A real agent would decompose with a model.
    ///
    /// - Author: Claude
    static func decompose(_ question: String) -> [String] {
        question.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Select the corpus documents relevant to a sub-question by keyword overlap — the parent's
    /// per-subtask provisioning. Pure, so the atomic-context guarantee is testable.
    ///
    /// - Author: Claude
    static func select(_ subQuestion: String, from corpus: [String]) -> [String] {
        let keywords = subQuestion.lowercased().split(separator: " ").map(String.init)
        return corpus.filter { doc in
            let text = doc.lowercased()
            return keywords.contains { $0.count > 2 && text.contains($0) }
        }
    }
}

/// The tailored environment the parent provisions for one subagent: its subtask plus exactly the
/// resources it needs (here, the relevant corpus slice). Carried as the delegate's task value, so a
/// subagent — running isolated — sees only this.
///
/// - Author: Claude
struct SubagentEnvironment: Codable, Hashable, Sendable {
    let subQuestion: String
    let documents: [String]

    static let empty = SubagentEnvironment(subQuestion: "", documents: [])
}
