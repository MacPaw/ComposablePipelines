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
/// reached). When the transcript approaches the context window, a compaction turn summarizes the
/// older middle (see ``CompactTranscript``) instead of losing it to truncation. Drive it with
/// ``PipelineRunner/run(_:executor:initialSlots:maxReexecutionDepth:optimizations:observingExecution:)``.
public struct CodingAgentPipeline: Pipeline {
    public typealias Output = String

    let task: String
    let maxTurns: Int
    let tools: [any ModelTool]
    let contextTokens: Int
    /// Per-response output cap. `nil` → don't send `max_tokens`; the server uses its own default.
    let maxOutputTokens: Int?
    let compaction: Bool

    @State var transcript: String
    @State var lastTurn: ModelTurn = ModelTurn()
    @State var reply: String = ""
    @State var turns: Int = 0
    @State var stalls: Int = 0
    // ModelTurn (not String) so an empty/truncated summarizer turn degrades gracefully instead of
    // throwing — the same reason the main loop uses ModelTurn output.
    @State var compactionSummary: ModelTurn = ModelTurn()

    /// How many consecutive empty turns to tolerate (with a nudge) before giving up.
    private let maxStalls = 3
    /// Characters of the transcript head (the task) kept verbatim through compaction.
    private let compactionHeadChars = 400

    public init(
        task: String,
        tools: [any ModelTool],
        maxTurns: Int = 15,
        contextTokens: Int = 8_192,
        maxOutputTokens: Int? = nil,
        compaction: Bool = true
    ) {
        self.task = task
        self.tools = tools
        self.maxTurns = maxTurns
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.compaction = compaction
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

    // Char budgets derived from the model's context window (~3 chars/token, conservative).
    // A large-context model (e.g. 256k) keeps full files and many turns without truncating;
    // a small one stays tight. Output tokens and headroom are reserved out of the input budget.
    private var snippetCharCap: Int { min(contextTokens * 3, 48_000) }
    private var transcriptCharCap: Int { max(8_000, (contextTokens - (maxOutputTokens ?? 4_096) - 2_048) * 3) }
    // Compact once the transcript passes 3/4 of the hard cap — before truncation would kick in.
    private var compactionTrigger: Int { transcriptCharCap * 3 / 4 }
    // Keep enough recent tail to stay coherent, but leave margin so the compacted transcript lands
    // well under the trigger (head + summary + tail ≈ 0.6·trigger) and doesn't immediately re-compact.
    private var compactionTailChars: Int { compactionTrigger / 3 }
    private var compactionSummaryTokens: Int { min(max(compactionTrigger / 12, 512), 2_048) }

    public var body: some Pipeline {
        While(reply.isEmpty && turns < maxTurns) {
            // Snapshot committed state at lowering so the dispatch tasks can extend it.
            let priorTranscript = transcript
            let priorStalls = stalls
            let cap = maxStalls
            let snippetCap = snippetCharCap
            let transcriptCap = transcriptCharCap

            if compaction && priorTranscript.count > compactionTrigger {
                // Compaction turn: summarize the older middle, preserving task header + recent tail.
                // No model turn happens this iteration; `reply` stays empty so the loop continues on
                // the compacted transcript next time.
                CompactTranscript(
                    summary: $compactionSummary,
                    transcript: $transcript,
                    head: String(priorTranscript.prefix(compactionHeadChars)),
                    middle: middle(of: priorTranscript),
                    tail: String(priorTranscript.suffix(compactionTailChars)),
                    maxTokens: compactionSummaryTokens)
            } else {
                // Work turn: model + tool dispatch.
                let registry = ToolRegistry(tools)

                let base = Model<ModelTurn>(systemPrompt)
                    .tools(tools.map(\.descriptor))
                // Apply an output cap only if one is configured; otherwise let the server decide.
                (maxOutputTokens.map { base.maxTokens($0) } ?? base)
                    .input { $transcript }
                    .assign(to: $lastTurn)
                // Extend the transcript: append tool results, or — on an empty turn — a nudge so the
                // next turn sees a different prompt and can recover. A tool-free answer turn is final
                // and leaves the transcript unchanged.
                Run($lastTurn) { turn in
                    if let calls = turn.toolCalls, !calls.isEmpty {
                        var updated = priorTranscript
                        for call in calls {
                            let result: String
                            do {
                                let output = try await registry.executeJSON(
                                    toolName: call.name, inputJSON: Data(call.arguments.utf8))
                                let text = (try? JSONDecoder().decode(String.self, from: output))
                                    ?? String(decoding: output, as: UTF8.self)
                                result = text.count > snippetCap
                                    ? String(text.prefix(snippetCap)) + "\n…[truncated]" : text
                            } catch {
                                // A malformed tool call (often truncated arguments when the model hit
                                // its output cap) must not abort the run — report it so the model can
                                // retry with a smaller call.
                                result = "error: could not run \(call.name) — \(error.localizedDescription). "
                                    + "The arguments may have been truncated; retry with less content "
                                    + "(e.g. write the file in smaller parts)."
                            }
                            // Echo only a short prefix of the arguments — a full file's content would
                            // otherwise be duplicated into the transcript.
                            let argsEcho = call.arguments.count > 200
                                ? String(call.arguments.prefix(200)) + "…" : call.arguments
                            updated += "\n\nAssistant: call \(call.name)(\(argsEcho))\n[\(call.name)]\n\(result)"
                        }
                        // Final safety net: if compaction is off or a single turn overflows, hard-trim.
                        if updated.count > transcriptCap {
                            let head = String(updated.prefix(400))
                            let tail = String(updated.suffix(transcriptCap - 400))
                            updated = head + "\n…[earlier context trimmed]…\n" + tail
                        }
                        return updated
                    }
                    if let reply = turn.reply, !reply.isEmpty { return priorTranscript }
                    return priorTranscript
                        + "\n\n(Your previous turn was empty. Call a tool to make progress, or write your final answer.)"
                }
                .assign(to: $transcript)
                // Track consecutive empty turns; reset on any productive turn.
                $lastTurn.map { turn in
                    let empty = (turn.toolCalls?.isEmpty ?? true) && (turn.reply?.isEmpty ?? true)
                    return empty ? priorStalls + 1 : 0
                }
                .assign(to: $stalls)
                $lastTurn.map { turn in
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
                .assign(to: $reply)
            }
            $turns.map { $0 + 1 }.assign(to: $turns)
        }
        $reply
    }

    /// The transcript minus the preserved head and tail — the portion compaction summarizes.
    private func middle(of full: String) -> String {
        guard full.count > compactionHeadChars + compactionTailChars else { return full }
        let start = full.index(full.startIndex, offsetBy: compactionHeadChars)
        let end = full.index(full.endIndex, offsetBy: -compactionTailChars)
        return String(full[start..<end])
    }
}

/// A sub-pipeline that compacts a long transcript: it summarizes `middle` via a `Model<String>`
/// call and rewrites `transcript` as `head + summary + tail`. Both `summary` and `transcript` are
/// the parent's bindings, so their slot ids stay stable across the reactive loop's re-lowerings.
struct CompactTranscript: Pipeline {
    typealias Output = String

    let summary: Binding<ModelTurn>
    let transcript: Binding<String>
    let head: String
    let middle: String
    let tail: String
    let maxTokens: Int

    private static let prompt = """
        You are compacting a long agent transcript to fit the context window. Summarize the excerpt \
        below into a dense recap that preserves the goal, decisions made, findings, file paths, and \
        tool results needed to continue the task. Output only the summary.
        """

    var body: some Pipeline {
        Model<ModelTurn>(Self.prompt)
            .maxTokens(maxTokens)
            .message(middle)
            .assign(to: summary)
        Run(summary) { turn in
            // An empty summarizer turn degrades to keeping just head + tail (no crash).
            head + "\n\n[Earlier context compacted:]\n" + (turn.reply ?? "") + "\n\n" + tail
        }
        .assign(to: transcript)
    }
}
