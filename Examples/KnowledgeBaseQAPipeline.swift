//
//  KnowledgeBaseQAPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineDSL

/// Retrieval-augmented answering: fetch context for the question from a provider, then answer
/// grounded only in what was retrieved.
///
/// Demonstrates:
/// - `From` — pull `[ContextItem]` from any `ContextItemsProvider` (a vector store, a memory
///   service, or a fixture like ``InMemoryKnowledgeBase`` below) using the question as the query.
/// - Routing retrieved context into a `Model` as its typed input.
///
/// (For input gating, see the `Guardrail` classification in ``ContentModerationPipeline`` /
/// ``ContentWriterPipeline``.)
struct KnowledgeBaseQAPipeline: Pipeline {
    typealias Output = String

    let knowledgeBase: any ContextItemsProvider

    @State var question: String
    @State var context: [ContextItem] = []
    @State var answer: String = ""

    var body: some Pipeline {
        // RETRIEVE: ask the provider for context relevant to the question.
        From(knowledgeBase, query: $question).assign(to: $context)

        // GENERATE: answer using only what was retrieved.
        Model<String>("""
            Answer the question using only the provided context. \
            If the context is insufficient, say you don't know.
            """)
            .input { $context }
            .assign(to: $answer)
    }
}

/// A trivial in-memory ``ContextItemsProvider``: returns the documents whose text contains a
/// word from the query. A real provider would query a vector store or a remote API; the shape
/// is the same — `fetch(query:)` returns `[ContextItem]`.
struct InMemoryKnowledgeBase: ContextItemsProvider {
    let sourceID: ContextSourceID
    let documents: [String]

    init(sourceID: ContextSourceID = "in-memory-kb", documents: [String]) {
        self.sourceID = sourceID
        self.documents = documents
    }

    func fetch(query: String) async throws -> [ContextItem] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return documents
            .filter { document in
                let haystack = document.lowercased()
                return terms.contains { term in term.count >= 3 && haystack.contains(term) }
            }
            .map { ContextItem(kind: .custom("doc"), source: sourceID, value: .string($0)) }
    }
}
