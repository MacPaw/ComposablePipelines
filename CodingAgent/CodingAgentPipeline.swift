//
//  CodingAgentPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines

/// An opencode-"Build"-style coding agent expressed entirely in the pipeline DSL: a ``AgentLoop``
/// over coding tools, with the coding-agent prompt and its stop logic.
///
/// `finish` ends the run whenever it is one of the tools (``defaultCodingTools(jail:bashTimeout:research:)``
/// includes it). The rest of the stop logic is declared with the same modifiers as ``AgentLoop``:
///
/// ```swift
/// CodingAgentPipeline(task: task, tools: defaultCodingTools(jail: jail), jail: jail)
///     .probe(watching: jail.root)          // warn off a fixed point; warned again later → answer now
///     .answerOnLastTurn()                  // the budget's last turn is a text answer
/// ```
///
/// For another agent shape, build a ``AgentLoop`` directly.
///
/// The loop is built once, in `init`, and stored: `body` is re-evaluated after every committed write,
/// and a loop built there would get fresh `@State` slots — and start over — every turn, so
/// ``AgentLoop`` traps when it is built or modified there. Store this pipeline, with its modifiers
/// applied, the same way: built in a `body`, it traps too.
public struct CodingAgentPipeline: Pipeline {
    public typealias Output = String

    let loop: AgentLoop

    /// - Parameters:
    ///   - conversation: The conversation before `task`, oldest first; see ``AgentLoop``.
    ///   - systemPrompt: Written for `tools`. The default assumes ``defaultCodingTools(jail:bashTimeout:research:)``
    ///     — it names bash and asks for tests to be run — so a host with a different set passes its own.
    ///     When `jail` is given, the working directory is appended to whichever prompt this is.
    ///   - enableThinking: `false` sends `enable_thinking: false`; `true` sends nothing, because the
    ///     engine reads an absent key as on.
    ///   - reportsToolCalls: Emit a `toolCall` to the run observer for every dispatched call. Pass
    ///     `false` when the tools report their own calls (an ElixTools `ToolDispatcher` with an `onCall`
    ///     hook), or each call is recorded twice. A name no tool answers to is reported either way: no
    ///     tool ever sees it.
    ///   - replaysReasoning: Keep each turn's reasoning in the history. Turn it on only for an
    ///     executor that sends prior reasoning back to the model, such as the local one: elsewhere it
    ///     would only fill the history budgets with text no request carries, and set off compaction
    ///     early.
    ///   - jail: The run's working directory, which the model is told.
    public init(
        task: String,
        conversation: [ConversationTurn] = [],
        tools: [any ToolExecutor],
        systemPrompt: String = CodingAgentPipeline.defaultSystemPrompt,
        maxTurns: Int = 15,
        contextTokens: Int = 8_192,
        maxOutputTokens: Int? = nil,
        compaction: Bool = true,
        enableThinking: Bool = true,
        reportsToolCalls: Bool = true,
        replaysReasoning: Bool = false,
        jail: PathJail? = nil,
        diagnostic: (@Sendable (String) -> Void)? = nil
    ) {
        var loop = AgentLoop(
            task: task, conversation: conversation, tools: tools, systemPrompt: systemPrompt, maxTurns: maxTurns,
            contextTokens: contextTokens, maxOutputTokens: maxOutputTokens, compaction: compaction,
            enableThinking: enableThinking, reportsToolCalls: reportsToolCalls,
            replaysReasoning: replaysReasoning, workingDirectory: jail?.root,
            diagnostic: diagnostic)
        if loop.canFinish { loop = loop.finishTool() }
        self.loop = loop
    }

    private init(loop: AgentLoop) {
        self.loop = loop
    }

    /// See ``AgentLoop/probe(watching:escalates:)``.
    ///
    /// - Author: Claude
    public func probe(watching root: URL, escalates: Bool = true) -> CodingAgentPipeline {
        CodingAgentPipeline(loop: loop.probe(watching: root, escalates: escalates))
    }

    /// See ``AgentLoop/answerOnLastTurn()``.
    ///
    /// - Author: Claude
    public func answerOnLastTurn() -> CodingAgentPipeline {
        CodingAgentPipeline(loop: loop.answerOnLastTurn())
    }

    /// See ``AgentLoop/stopping(_:)``.
    ///
    /// - Author: Claude
    public func stopping(_ policy: any StopPolicy) -> CodingAgentPipeline {
        CodingAgentPipeline(loop: loop.stopping(policy))
    }

    /// The prompt for ``defaultCodingTools(jail:bashTimeout:research:)``.
    public static let defaultSystemPrompt = """
        You are a coding agent working inside a fixed working directory. You can read, list, \
        search, write, and edit files, and run bash — all confined to that directory. \
        Investigate before you change anything: directories may hold relevant files, so list and \
        read into subdirectories before concluding something is absent. Make minimal, correct changes.

        ALWAYS VERIFY YOUR WORK BEFORE FINISHING. After making a change, confirm it actually \
        works — don't just assume it does. If the task or working directory has tests, run them. \
        Otherwise execute your code or write a small throwaway check (e.g. `python3 -c "..."` or a \
        short script) to confirm it behaves exactly as the task requires, including edge cases. \
        Do not declare the task done until you have observed it pass.

        Work efficiently: every turn must make NEW progress. Never repeat a tool call that already \
        succeeded — do not re-write a file you just wrote or re-read an unchanged file. Each turn, \
        either call a tool to advance the task or, once it is fully done AND verified, reply with a \
        short summary. Never return an empty turn, and do not reply while work remains.
        """

    public var body: some Pipeline {
        loop
    }
}
