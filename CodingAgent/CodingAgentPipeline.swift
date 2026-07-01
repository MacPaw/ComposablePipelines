//
//  CodingAgentPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines

/// An opencode-"Build"-style coding agent expressed entirely in the pipeline DSL.
///
/// Each turn the model sees the running transcript plus the tool schemas and returns a
/// ``ModelTurn``. Tool calls are dispatched through a `ToolRegistry` and their results appended to
/// the transcript; the `While` loop ends when the model returns a final `reply` (or `maxTurns` is
/// reached). Drive it with ``PipelineRunner/run(_:executor:initialSlots:maxReexecutionDepth:optimizations:observingExecution:)``.
public struct CodingAgentPipeline: Pipeline {
    public typealias Output = String

    let task: String
    let maxTurns: Int
    let tools: [any ModelTool]

    @State var transcript: String
    @State var lastTurn: ModelTurn = ModelTurn()
    @State var reply: String = ""
    @State var turns: Int = 0
    @State var stalls: Int = 0

    /// How many consecutive empty turns to tolerate (with a nudge) before giving up.
    private let maxStalls = 3

    public init(task: String, tools: [any ModelTool], maxTurns: Int = 15) {
        self.task = task
        self.tools = tools
        self.maxTurns = maxTurns
        _transcript = State(wrappedValue: "Task: \(task)")
    }

    private var systemPrompt: String {
        """
        You are a coding agent working inside a fixed working directory. You can read, list, \
        search, write, and edit files, and run bash — all confined to that directory. \
        Investigate before you change anything: directories may hold relevant files, so list and \
        read into subdirectories before concluding something is absent. Every turn, either call a \
        tool to make progress or, when the task is fully done, reply with a short summary — never \
        return an empty turn. Make minimal, correct changes. Do not reply while work remains.
        """
    }

    public var body: some Pipeline {
        While(condition: { reply.isEmpty && turns < maxTurns }) {
            // Snapshot committed state at lowering so the dispatch tasks can extend it.
            let priorTranscript = transcript
            let priorStalls = stalls
            let cap = maxStalls
            let registry = ToolRegistry(tools)

            $lastTurn.set {
                Model<ModelTurn>()
                    .tools(tools.map(\.descriptor))
                    .systemPrompt(systemPrompt)
                    .maxTokens(8192)
                    .input { $transcript.get() }
            }
            // Extend the transcript: append tool results, or — on an empty turn — a nudge so the
            // next turn sees a different prompt and can recover. A tool-free answer turn is final
            // and leaves the transcript unchanged.
            $transcript.set {
                ClientTask(input: $lastTurn) { turn in
                    if let calls = turn.toolCalls, !calls.isEmpty {
                        var updated = priorTranscript
                        for call in calls {
                            let output = try await registry.executeJSON(
                                toolName: call.name, inputJSON: Data(call.arguments.utf8))
                            let text = (try? JSONDecoder().decode(String.self, from: output))
                                ?? String(decoding: output, as: UTF8.self)
                            let snippet = text.count > 4000 ? String(text.prefix(4000)) + "\n…[truncated]" : text
                            updated += "\n\nAssistant: call \(call.name)(\(call.arguments))\n[\(call.name)]\n\(snippet)"
                        }
                        return updated
                    }
                    if let reply = turn.reply, !reply.isEmpty { return priorTranscript }
                    return priorTranscript
                        + "\n\n(Your previous turn was empty. Call a tool to make progress, or write your final answer.)"
                }
            }
            // Track consecutive empty turns; reset on any productive turn.
            $stalls.set {
                ClientTask(input: $lastTurn) { turn in
                    let empty = (turn.toolCalls?.isEmpty ?? true) && (turn.reply?.isEmpty ?? true)
                    return empty ? priorStalls + 1 : 0
                }
            }
            $reply.set {
                ClientTask(input: $lastTurn) { turn in
                    // A turn that also requested tools is NOT final — many models emit a preamble
                    // ("I'll list the files…") alongside the tool call. Keep looping so the tool
                    // results feed the next turn.
                    if let calls = turn.toolCalls, !calls.isEmpty { return "" }
                    // A tool-free turn with text is the final answer.
                    if let reply = turn.reply, !reply.isEmpty { return reply }
                    // Empty turn: keep going (with the nudge above) until stalls persist, then stop.
                    return priorStalls + 1 >= cap
                        ? "(the model kept returning empty turns — try rephrasing or a smaller step)"
                        : ""
                }
            }
            $turns.set {
                ClientTask(input: $turns) { $0 + 1 }
            }
        }
        $reply.get()
    }
}
