//
//  Demo.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines
import OpenAIExecutor

// MARK: - Demo pipeline

/// Three-step refinement pipeline: draft → revise → polish.
/// Each step consumes the prior step's output via @State, demonstrating a genuine
/// sequential refinement chain where no step's output is discarded.
///
/// Each step requests a generous `maxTokens` budget: reasoning models spend tokens
/// thinking before they emit any reply, so a small default can truncate them
/// (`finish_reason: "length"`) before any content is produced.
struct DemoArticlePipeline: Pipeline {
    typealias Output = String

    let topic: String

    @State var draft: String = ""
    @State var revised: String = ""
    @State var polished: String = ""

    var body: some Pipeline {
        $draft.set {
            Model<String>()
                .systemPrompt("Write a single short, punchy paragraph about the topic. "
                    + "Respond with only the paragraph — no preamble, no options, no headings.")
                .maxTokens(4096)
                .message(topic)
        }

        $revised.set {
            Model<String>()
                .systemPrompt("Rewrite the following paragraph to be clearer and more engaging. "
                    + "Respond with only the rewritten paragraph — no preamble, no options, no commentary.")
                .maxTokens(4096)
                .input { $draft.get() }
        }

        $polished.set {
            Model<String>()
                .systemPrompt("Polish the following paragraph: tighten the wording and fix any awkward phrasing. "
                    + "Respond with only the final paragraph — no preamble or commentary.")
                .maxTokens(4096)
                .input { $revised.get() }
        }

        $polished.get()
    }
}

// MARK: - Entry point

@main
enum Demo {
    static func main() async {
        do {
            let config = try OpenAIChatExecutor.Config.fromEnvironment()
            FileHandle.standardError.write(
                Data("→ model \(config.model) @ \(config.baseURL.absoluteString)\n".utf8)
            )

            let topic = CommandLine.arguments.dropFirst().first ?? "Swift result builders"
            let pipeline = DemoArticlePipeline(topic: topic)

            let graph = PipelineCompiler(optimizations: .parallelize).compile(pipeline.loweredGraph())
            let walker = PipelineWalker(executor: OpenAIChatExecutor(config: config))

            let result = try await walker.run(
                graph: graph,
                observingExecution: { event in
                    FileHandle.standardError.write(Data("· \(event)\n".utf8))
                }
            )

            let article = (try? JSONDecoder().decode(String.self, from: result)) ?? ""
            print("\n=== Article ===\n\(article)")

        } catch OpenAIChatExecutorError.missingAPIKey {
            FileHandle.standardError.write(
                Data("error: set OPENAI_API_KEY (and optionally OPENAI_BASE_URL / OPENAI_MODEL)\n".utf8)
            )
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
