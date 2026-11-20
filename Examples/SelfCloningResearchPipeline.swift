//
//  SelfCloningResearchPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// A **self-cloning** agent: it decomposes its topic into sub-topics and delegates each to a delegate of
/// **itself**, one level deeper, then combines the delegates' answers. Recursion bottoms out when a topic
/// is atomic (no further decomposition), and the shared spawn budget bounds the whole tree.
///
/// Demonstrates:
/// - `DelegateSelf` — the agent re-runs *itself* per sub-topic (no separate child pipeline). Each delegate
///   is seeded with its sub-topic via `taskInput` and runs in its own isolated scope.
/// - A **data base case** (`decompose` returns `[]` for an atomic topic) plus the budget as backstop,
///   so the self-recursion is finite.
/// - A single model turn that serves both roles: a leaf answers its topic; an internal node combines
///   its delegates' answers — chosen by the built input, so no value-dependent branching is needed (a
///   delegate runs as one static walk).
///
/// This level's topic lives in the `current` slot, **seeded per delegate** via `DelegateSelf`'s `taskInput`;
/// the root run leaves it empty and falls back to the top-level `topic`. Resolving it writes a
/// **separate** `effective` slot (never the slot it reads) so the read→write dependency is explicit
/// and safe under the parallelizing compiler.
struct SelfCloningResearchPipeline: Pipeline {
    typealias Output = String

    /// The top-level topic; seeds the root run only (delegates are seeded through `current`).
    let topic: String

    /// Seeded per delegate via `DelegateSelf`'s `taskInput`; empty on the root run.
    @State var current: String = ""
    /// This level's resolved topic: the seeded sub-topic (a delegate) or the root `topic` (top level).
    @State var effective: String = ""
    /// Sub-topics for this level (empty ⇒ atomic ⇒ base case).
    @State var parts: [String] = []
    /// The delegates' gathered answers (`nil` marks a budget-refused delegate).
    @State var childAnswers: [String?] = []
    /// The model input built from this topic + the delegates' answers.
    @State var digest: String = ""
    @State var answer: String = ""

    var body: some Pipeline {
        // 1. Resolve this level's topic into a *separate* slot: the seeded sub-topic (a delegate) or the
        //    root topic (top level). Reading `current` and writing `effective` keeps the dependency
        //    explicit (no read-modify-write of one slot, which the parallelizer could reorder).
        $effective.set { Run(input: $current) { [topic] c in c.isEmpty ? topic : c } }

        // 2. Decompose into sub-topics — empty when atomic, the recursion's data base case.
        $parts.set { Run(input: $effective) { Self.decompose($0) } }

        // 3. Recurse: a delegate of THIS agent per sub-topic. Empty `parts` ⇒ no delegates spawned (leaf);
        //    the shared budget bounds an otherwise unbounded self-tree. `inherit: [.tools]` forwards
        //    the client-action provider so each delegate can run the agent's OWN `Run` steps (decompose /
        //    digest are the agent's logic, which lower to client actions) — without it a delegate can't
        //    re-run its own body.
        $childAnswers.set {
            DelegateSelf<String, String>(
                tasks: $parts, taskInput: $current,
                budget: .init(total: 32, leafReserve: 4), inherit: [.tools])
        }

        // 4. Build the model input from this topic + the delegates' answers (empty at a leaf).
        $digest.set {
            Run($effective, $childAnswers) { current, answers in
                let kids = answers.compactMap { $0 }
                if kids.isEmpty {
                    return "Answer this concisely:\n\(current)"
                }
                let joined = kids.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                return "Topic: \(current)\n\nSub-answers:\n\(joined)\n\nCombine these into one coherent answer."
            }
        }

        // 5. One model turn: a leaf answers its topic; an internal node combines its delegates' answers.
        $answer.set {
            Model<String>()
                .systemPrompt("Answer the topic, or combine the sub-answers into one, as the input asks.")
                .input { $digest.get() }
        }

        $answer.get()
    }

    /// Split a topic into two halves by word count; a topic of ≤ 2 words is atomic (returns `[]`), so
    /// the recursion terminates on data alone (the budget is only a backstop). Deterministic, so the
    /// example runs reproducibly under a scripted backend.
    ///
    /// - Author: Claude
    static func decompose(_ topic: String) -> [String] {
        let words = topic.split(separator: " ").map(String.init)
        guard words.count > 2 else { return [] }
        let mid = words.count / 2
        return [words[..<mid].joined(separator: " "), words[mid...].joined(separator: " ")]
    }
}
