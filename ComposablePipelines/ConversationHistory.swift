//
//  ConversationHistory.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST
import PipelineDSL

/// Keeping an agent's history as turns rather than as one long string.
///
/// Both agents in this package used to concatenate the conversation into a single `user`
/// message — the model's own calls and even its own reasoning were replayed to it as somebody
/// else's prose. Measured on the wire, that was two messages per request where the upstream
/// agent sent up to 41, and two thirds of the text was replayed thinking.
///
/// Turns carry a structural hazard a string does not: a `tool` turn is only meaningful next to
/// the `assistant` turn that asked for it. Every operation that shortens a history — trimming,
/// compaction — has to respect that, or it produces a `tool_call_id` referring to nothing and
/// the request is rejected outright.
///
/// - Author: Claude
public enum ConversationHistory {

    /// One turn as plain text, for anything that needs to read the conversation as prose:
    /// summarisation input, and the hooks that inspect a transcript tail.
    public static func render(_ turn: ConversationTurn) -> String {
        switch turn.role {
        case "assistant":
            var text = turn.content.isEmpty ? "" : "Assistant: \(turn.content)"
            for call in turn.toolCalls ?? [] {
                let echo = call.arguments.count > 200
                    ? String(call.arguments.prefix(200)) + "…" : call.arguments
                text += (text.isEmpty ? "" : "\n") + "Assistant: call \(call.name)(\(echo))"
            }
            return text
        case "tool":
            return "[tool]\n\(turn.content)"
        default:
            return turn.content
        }
    }

    /// The whole history as prose.
    public static func render(_ turns: [ConversationTurn]) -> String {
        turns.map(render).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Rough size, used against the character budgets derived from the context window.
    /// Counts the reasoning a turn carries: an executor that replays it (the local one does) sends
    /// it with the turn, and a budget that missed it let the prompt outgrow the window unseen. All of
    /// it is counted, although a chat template may strip some: which turns keep it is each model's
    /// policy, and an overestimate only trims early.
    public static func charCount(_ turns: [ConversationTurn]) -> Int {
        turns.reduce(0) { $0 + charCount($1) }
    }

    static func charCount(_ turn: ConversationTurn) -> Int {
        turn.content.count + (turn.reasoning?.count ?? 0)
            + (turn.toolCalls ?? []).reduce(0) { $0 + $1.name.count + $1.arguments.count }
    }

    /// Drop leading turns that cannot stand on their own.
    ///
    /// A `tool` turn whose `assistant` turn has been cut away references a `tool_call_id` that is
    /// no longer in the request. Providers reject that, so a suffix is only safe once it starts
    /// at a turn that opens an exchange.
    public static func safeSuffix(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        var out = turns[...]
        while let first = out.first, first.role == "tool" { out = out.dropFirst() }
        return Array(out)
    }

    /// Group a history into exchanges: an assistant turn together with the tool turns that
    /// answer it, or any other turn on its own.
    ///
    /// Everything that shortens a history has to work in these units. Cutting between an
    /// assistant turn and its results either produces a `tool_call_id` the request cannot
    /// justify, or — if those orphans are then dropped — silently deletes the largest thing in
    /// the conversation.
    ///
    /// - Author: Claude
    public static func exchanges(_ turns: [ConversationTurn]) -> [[ConversationTurn]] {
        var out: [[ConversationTurn]] = []
        for turn in turns {
            if turn.role == "tool", var last = out.last, last.first?.role == "assistant" {
                last.append(turn)
                out[out.count - 1] = last
            } else {
                out.append([turn])
            }
        }
        return out
    }

    /// Keep the opening turns and as much of the recent tail as the budget allows.
    ///
    /// The opening is preserved because it holds the task: an agent that forgets what it was
    /// asked cannot recover, while one that forgets the middle can. At least one exchange is
    /// always kept, even when it alone exceeds the budget — a single oversized tool result is
    /// still the most recent thing that happened, and the hard truncation that follows it
    /// elsewhere is a better answer than an empty history.
    public static func trimmed(_ turns: [ConversationTurn],
                               toCharacters budget: Int,
                               keepingFirst head: Int = 1) -> [ConversationTurn] {
        guard charCount(turns) > budget, turns.count > head else { return turns }
        // Old reasoning goes before any exchange does: losing an old thought costs less than losing a
        // tool result, and dropping exchanges first would keep the thought and drop the result. The
        // newest thought stays: it is the plan the next call follows, and an old exchange is worth
        // less. ``fit(_:toCharacters:)`` gives it up last, before any text is cut.
        let turns = droppingReasoning(turns, toCharacters: budget, keepingLatest: true)
        guard charCount(turns) > budget else { return turns }
        let opening = Array(turns.prefix(head))
        var tail: [ConversationTurn] = []
        var used = charCount(opening)
        for group in exchanges(Array(turns.dropFirst(head))).reversed() {
            let size = charCount(group)
            if used + size > budget, !tail.isEmpty { break }
            tail.insert(contentsOf: group, at: 0)
            used += size
        }
        return fit(opening + safeSuffix(tail), toCharacters: budget)
    }

    /// Drop reasoning, then shorten turn contents, then oversized tool-call arguments, until the
    /// history fits, oldest first. Reasoning goes first because it is the cheapest to lose: what a
    /// turn did is in its content and calls.
    ///
    /// The last resort, for when dropping whole exchanges cannot help because the one that must
    /// be kept is itself over budget. Structure is preserved — every `tool` turn keeps its id and
    /// its place — and only the text shrinks, which is the difference between a request that is
    /// merely shorter and one the provider rejects.
    ///
    /// - Author: Claude
    public static func fit(_ turns: [ConversationTurn],
                           toCharacters budget: Int) -> [ConversationTurn] {
        guard charCount(turns) > budget else { return turns }
        var out = droppingReasoning(turns, toCharacters: budget)
        var size = charCount(out)
        let marker = "\n…[truncated]"
        // Oldest first: recent results are what the next turn reasons about.
        for index in out.indices {
            guard size > budget else { break }
            let turn = out[index]
            guard turn.content.count > 200 else { continue }
            let keep = max(200, turn.content.count - (size - budget) - marker.count)
            guard keep < turn.content.count else { continue }
            size -= charCount(turn)
            out[index] = ConversationTurn(
                role: turn.role,
                content: String(turn.content.prefix(keep)) + marker,
                toolCalls: turn.toolCalls,
                toolCallID: turn.toolCallID,
                reasoning: turn.reasoning)
            size += charCount(out[index])
        }
        // Still over: the bulk is in tool-call arguments — a large `write_file` whose result is
        // one line. `charCount` counts them, so shrinking only contents could leave the history
        // above the budget and re-trigger compaction forever. A prefix of JSON is not JSON, so an
        // oversized call is replaced by a valid stub; its id and name stay, and with them the
        // exchange the provider checks.
        for index in out.indices {
            guard size > budget else { break }
            let turn = out[index]
            guard let calls = turn.toolCalls,
                  calls.contains(where: { $0.arguments.count > 200 }) else { continue }
            size -= charCount(turn)
            out[index] = ConversationTurn(
                role: turn.role,
                content: turn.content,
                toolCalls: calls.map { call in
                    call.arguments.count > 200
                        ? ToolCall(id: call.id, name: call.name, arguments:
                            #"{"omitted":"\#(call.arguments.count) characters of arguments"}"#)
                        : call
                },
                toolCallID: turn.toolCallID,
                reasoning: turn.reasoning)
            size += charCount(out[index])
        }
        return out
    }

    /// Removes reasoning, oldest turn first, until the history fits or none is left. The first
    /// thing both ``trimmed(_:toCharacters:keepingFirst:)`` and ``fit(_:toCharacters:)`` give up.
    ///
    /// - Parameter keepingLatest: Leave the newest turn's reasoning in place.
    ///
    /// - Author: Claude
    static func droppingReasoning(_ turns: [ConversationTurn],
                                  toCharacters budget: Int,
                                  keepingLatest: Bool = false) -> [ConversationTurn] {
        var out = turns
        var size = charCount(out)
        let kept = keepingLatest ? out.lastIndex { !($0.reasoning ?? "").isEmpty } : nil
        for index in out.indices where index != kept {
            guard size > budget else { break }
            let turn = out[index]
            guard let reasoning = turn.reasoning, !reasoning.isEmpty else { continue }
            size -= reasoning.count
            out[index] = ConversationTurn(role: turn.role, content: turn.content,
                                          toolCalls: turn.toolCalls, toolCallID: turn.toolCallID)
        }
        return out
    }
}

/// Compacts a long history: summarises the middle into one turn and keeps the opening and the
/// recent tail.
///
/// The summary is inserted as a `user` turn rather than an `assistant` one: it is the harness
/// speaking about the conversation, and attributing it to the model would be the same mistake
/// the flat transcript made.
///
/// - Author: Claude
public struct CompactHistory: Pipeline {
    public typealias Output = [ConversationTurn]

    let summary: Binding<ModelTurn>
    let history: Binding<[ConversationTurn]>
    let head: [ConversationTurn]
    let middle: String
    let tail: [ConversationTurn]
    let maxTokens: Int
    let enableThinking: Bool

    /// - Parameter enableThinking: Same meaning as ``AgentLoop``'s — a caller that turned
    ///   thinking off for its turns gets it off for the summary too.
    public init(summary: Binding<ModelTurn>, history: Binding<[ConversationTurn]>,
                head: [ConversationTurn], middle: String, tail: [ConversationTurn],
                maxTokens: Int, enableThinking: Bool = true) {
        self.summary = summary
        self.history = history
        self.head = head
        self.middle = middle
        self.tail = tail
        self.maxTokens = maxTokens
        self.enableThinking = enableThinking
    }

    private static let prompt = """
        You are compacting a long agent transcript to fit the context window. Summarize the excerpt \
        below into a dense recap that preserves the goal, decisions made, findings, file paths, and \
        tool results needed to continue the task. Output only the summary.
        """

    public var body: some Pipeline {
        let model = Model<ModelTurn>(Self.prompt)
        (enableThinking ? model : model.parameter("enable_thinking", false))
            .maxTokens(maxTokens)
            .message(middle)
            .assign(to: summary)
        Run(summary) { turn -> [ConversationTurn] in
            // An empty summarizer turn degrades to keeping head + tail (no crash).
            let recap = ConversationTurn(
                role: "user",
                content: "[Earlier context compacted:]\n" + (turn.reply ?? ""))
            return head + [recap] + ConversationHistory.safeSuffix(tail)
        }
        .assign(to: history)
    }
}
