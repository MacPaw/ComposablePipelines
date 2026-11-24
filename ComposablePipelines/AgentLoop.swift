//
//  AgentLoop.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST
@_spi(Internals) import PipelineDSL  // ExecutionContext.isEmittingPipelineGraph — the build-site trap
@_spi(Internals) import ExecutionEngine  // TelemetryContext — emit tool spans via the ambient observer

/// How an ``AgentLoop`` compacts: what its summarizer reads and how its turn is sent. The default
/// is a recap of a transcript, which asks nothing of the executor. The fact summary is what
/// measured best on a small model, from a summarizer that can only write text — and that is the
/// executor's to enforce: shown the task with no ban in force, the model answers most compactions
/// with the next call, and every such reply lands as an empty summary. Turn it on where the
/// executor honours `tool_calls: false` (the in-process engine does; an HTTP route takes no such key).
///
/// - Author: Claude
public struct CompactionOptions: Sendable, Equatable {
    /// The summarizer reads the older middle as a report of calls and their results, under the
    /// task, and replies with the facts the task still needs (``ConversationHistory/report(_:)``).
    /// Off, it reads the middle as a transcript and replies with a recap of it — which a small model
    /// continues instead of writing, call by call, in half the compactions measured.
    public var factSummary: Bool
    /// The summarizer's turn may open a tool call. Off, the turn carries `tool_calls: false` and an
    /// executor that honours it bans the call grammar at decode: the reply is text, whatever the
    /// model meant to do. Shown the task, a small model takes it as its own and answers most
    /// compactions with the next call, and every such reply lands as an empty summary; the ban is
    /// the one lever measured to end that (a summarizer that thinks less, or a report without call
    /// syntax, or a worked example, did not).
    public var summarizerMayCall: Bool

    public init(factSummary: Bool = false, summarizerMayCall: Bool = false) {
        self.factSummary = factSummary
        self.summarizerMayCall = summarizerMayCall
    }
}

/// How much of its earlier reasoning an ``AgentLoop`` keeps in the history it sends back. The
/// newest thought always stays whole (see ``ConversationHistory/retainingReasoning(_:as:pressure:)``).
///
/// - Author: Claude
public enum ReasoningRetention: Sendable, Equatable {
    /// Every thought until the history reaches this fraction of the compaction trigger, then the
    /// newest alone — thoughts are the first thing given up under pressure, before any compaction.
    /// The loop's default, at two thirds: the cheapest retention on a small model that was not
    /// also the slowest, and the one that passed most.
    case untilPressure(Double)
    /// Every thought, until the history budgets drop the oldest.
    case all
}

/// What the history shows of a tool result once it has aged. The newest exchanges keep their
/// results; older ones show a one-line stub naming the call, and the model calls again for what it
/// needs. A `read_file` result is masked whatever its age once a later exchange read or wrote the
/// same path. The calls and the thoughts stay. Masking takes tokens out of the window without a
/// summarizer. The newest exchange alone is what measured: a wider window kept a one-exchange
/// fan-out of reads whole and saved nothing.
///
/// - Author: Claude
public struct ObservationMasking: Sendable, Equatable {
    /// Results older than the newest `keepExchanges` exchanges are masked.
    public var keepExchanges: Int
    /// Mask only once the history has reached this fraction of the compaction trigger; nil masks
    /// from the first turn. A run that never nears the trigger is then never touched.
    public var atPressure: Double?
    /// The newest `read_file` result of every path stays whole whatever the other rules say: a
    /// model that has just read a file is never shown a stub of it, so an edit does not send it
    /// reading the same file again and again.
    public var keepsNewestReadPerPath: Bool

    public init(keepExchanges: Int = 1, atPressure: Double? = nil, keepsNewestReadPerPath: Bool = false) {
        self.keepExchanges = keepExchanges
        self.atPressure = atPressure
        self.keepsNewestReadPerPath = keepsNewestReadPerPath
    }
}

/// A tool-calling agent loop, with its stop logic declared as modifiers.
///
/// ```swift
/// let loop = AgentLoop(task: task, tools: tools, systemPrompt: prompt, maxTurns: 30)
///     .finishTool()                        // a `finish` call ends the run with its message
///     .probe(watching: workspace)          // warn off a fixed point; warned again later → answer now
///     .answerOnLastTurn()                  // the budget's last turn is a text answer
/// ```
///
/// Each turn the model sees the conversation so far — role-tagged turns, its own tool calls bound
/// to their results — plus the tool schemas, and returns a ``ModelTurn``. Tool calls are dispatched
/// through a `ToolRegistry` and their results appended as `tool` turns; the loop ends when the model
/// returns a tool-free `reply`, a ``StopPolicy`` ends it, or `maxTurns` is reached. When the history
/// approaches the context window, a compaction turn summarizes the older middle (see
/// ``CompactHistory``) instead of losing it to truncation. Drive it with
/// ``PipelineRunner/run(_:executor:initialSlots:maxReexecutionDepth:optimizations:observingExecution:)``.
///
/// **Build it once**: create it, and apply its modifiers, outside lowering — as the root pipeline
/// or as a stored property set in `init`. A loop created or modified inside a `body` traps, because
/// the DSL re-evaluates `body` after every committed write, `@State` takes a fresh slot id each time
/// a pipeline value is created, and each modifier makes a new stop policy: the loop would start over
/// every turn. This is stricter than "once": a value made lazily on first use during a lowering
/// (a `static let` first read in a `body`) traps too. The modifiers return copies, which keep the
/// slots.
///
/// **One loop value per run.** The stop policies remember the run they watch (the probe's history,
/// whether it escalated) and nothing clears that when a run ends, so a value run a second time
/// starts where the first one stopped. Build a fresh loop for each run.
///
/// The loop takes any `ToolExecutor`, not only DSL-authored `ModelTool`s, so a host can put its own
/// tool implementations behind it (the `CodingAgent` module's `defaultCodingTools(jail:)` is the
/// lightweight set this package ships). What the loop adds to the conversation on its own is limited
/// to what it can observe itself — the call, the result text, and whether a turn was empty or a call
/// repeated — never a claim about what a tool did.
///
/// - Author: Claude
public struct AgentLoop: Pipeline {
    public typealias Output = String

    let task: String
    /// How many turns open the history: the earlier conversation the run continues, then the task.
    /// Trimming and compaction never drop them — they are what the run is about.
    ///
    /// - Author: Claude
    let openingTurns: Int
    let maxTurns: Int
    private(set) var tools: [any ToolExecutor]
    let systemPrompt: String
    let contextTokens: Int
    /// Per-response output cap. `nil` → don't send `max_tokens`; the server uses its own default.
    private(set) var maxOutputTokens: Int?
    private(set) var compaction: Bool
    let enableThinking: Bool
    let reportsToolCalls: Bool
    /// Whether the model's turns keep their reasoning in the history. On only where the executor
    /// sends it back to the model (the local one, through its chat template): a turn carries what the
    /// next request will show, and the history budgets count it.
    ///
    /// - Author: Claude
    let replaysReasoning: Bool
    /// Provider-specific arguments every work turn sends (``Model/parameter(_:_:)`` on the step), keyed
    /// by their raw key — an engine's repetition penalty, say. The compaction summarizer sends them
    /// too: it decodes as a work turn does. A forced answer turn sends none. The loop's own keys —
    /// thinking, preserved thinking, the summarizer's call ban — are applied after them and win.
    ///
    /// - Author: Claude
    private(set) var modelParameters: [String: JSONValue] = [:]
    /// How the loop compacts. See ``CompactionOptions``.
    private(set) var compactionOptions = CompactionOptions()
    /// How much earlier reasoning the history keeps. See ``ReasoningRetention``.
    private(set) var reasoningRetention = ReasoningRetention.untilPressure(2.0 / 3.0)
    /// What the history shows of older tool results; nil shows every result whole. See ``ObservationMasking``.
    private(set) var masking: ObservationMasking?
    /// Whether every work turn ends with the task restated as the last user message.
    private(set) var restatesTask = false

    /// When the run stops, and that it stops with an answer (see ``StopPolicy``), in the order the
    /// modifiers were applied — the first policy to name a reason for forcing an answer is the one
    /// the transcript records.
    ///
    /// Held as a stored property rather than `@State`: state that must outlive a lowering (the
    /// probe's memory) lives in the policy objects, created once with the loop.
    private(set) var policies: [any StopPolicy] = []
    /// Where this run works, as the model must be told it. `nil` when no working directory was supplied.
    ///
    /// - Author: Claude
    let workingDirectory: String?
    /// Harness-interpretation notes — what the scaffold decided, as opposed to what the model
    /// said. Rendered into the transcript as `[harness]` lines so a run can be audited from its
    /// stored data instead of from inference about it.
    let diagnostic: (@Sendable (String) -> Void)?

    /// The conversation, as turns. Was a single string until the wire audit showed the model
    /// being handed its own calls — and its own reasoning — as `user` prose.
    ///
    /// - Author: Claude
    @State var history: [ConversationTurn]
    /// This turn's extra input, on top of the history. Empty on almost every turn; the executor
    /// omits an empty trailing message rather than asking the model to answer nothing.
    ///
    /// - Author: Claude
    @State var turnInput: String = ""
    @State var lastTurn: ModelTurn = ModelTurn()
    @State var reply: String = ""
    @State var turns: Int = 0
    @State var stalls: Int = 0
    // ModelTurn (not String) so an empty/truncated summarizer turn degrades gracefully instead of
    // throwing — the same reason the main loop uses ModelTurn output.
    @State var compactionSummary: ModelTurn = ModelTurn()

    /// How many consecutive empty turns to tolerate (with a nudge) before giving up.
    private let maxStalls = 3

    /// What a failed tool call tells the model — the same reading as ElixTools' `ToolDispatcher`.
    /// `localizedDescription` alone renders a plain Swift error as "The operation couldn't be
    /// completed", dropping the detail an arbitrary ``ToolExecutor`` put in its `description`.
    static func detail(of error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        if type(of: error) is NSError.Type { return error.localizedDescription }
        if let described = error as? CustomStringConvertible { return described.description }
        return String(describing: error)
    }

    /// - Parameters:
    ///   - conversation: The conversation before `task`, oldest first, when the run continues one
    ///     (a chat follow-up). Sent ahead of the task on every turn; trimming and compaction never drop
    ///     these turns (only a history over the hard cap shortens their text). A `tool` turn must
    ///     follow the assistant turn whose call it answers, with that call's id.
    ///   - systemPrompt: Written for `tools`. When `workingDirectory` is given, it is appended
    ///     to it, and each stop policy may add a paragraph (see ``StopPolicy/promptAddendum``).
    ///   - enableThinking: `false` sends `enable_thinking: false`; `true` sends nothing, because the
    ///     engine reads an absent key as on.
    ///   - reportsToolCalls: Emit a `toolCall` to the run observer for every dispatched call. Pass
    ///     `false` when the tools report their own calls (an ElixTools `ToolDispatcher` with an `onCall`
    ///     hook), or each call is recorded twice. A name no tool answers to is reported either way: no
    ///     tool ever sees it.
    ///   - replaysReasoning: Keep each turn's reasoning in the history, and ask the chat template to
    ///     keep all of it (`preserve_thinking`). Turn it on only for an executor that sends prior
    ///     reasoning back to the model, such as the local one: elsewhere it would only fill the
    ///     history budgets with text no request carries, and set off compaction early.
    ///   - workingDirectory: Where the run works — told to the model, which builds paths from it.
    ///   - diagnostic: Harness-interpretation notes for the transcript.
    public init(
        task: String,
        conversation: [ConversationTurn] = [],
        tools: [any ToolExecutor],
        systemPrompt: String,
        maxTurns: Int = 15,
        contextTokens: Int = 8_192,
        maxOutputTokens: Int? = nil,
        compaction: Bool = true,
        enableThinking: Bool = true,
        reportsToolCalls: Bool = true,
        replaysReasoning: Bool = false,
        workingDirectory: URL? = nil,
        diagnostic: (@Sendable (String) -> Void)? = nil
    ) {
        // Built while lowering, the loop is rebuilt on every re-lowering with fresh state, and the
        // run goes on until the walker's re-execution limit without an error.
        if ExecutionContext.isEmittingPipelineGraph { fatalError(Self.builtWhileLowering) }
        self.task = task
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxTurns = maxTurns
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.compaction = compaction
        self.enableThinking = enableThinking
        self.reportsToolCalls = reportsToolCalls
        self.replaysReasoning = replaysReasoning
        // A host that confines paths should pass the same form its check compares against, so a
        // path the model builds from it passes that check.
        self.workingDirectory = workingDirectory?.path
        self.diagnostic = diagnostic
        self.openingTurns = conversation.count + 1
        _history = State(wrappedValue: conversation + [ConversationTurn(role: "user", content: "Task: \(task)")])
    }

    /// Why a loop created or given a stop policy while a pipeline is lowered traps, and what to
    /// write instead.
    static let builtWhileLowering = """
        AgentLoop was created or given a stop policy while a pipeline was being lowered: inside a \
        `body` or a builder closure (ForEach, If, Delegate), directly or through a pipeline that \
        stores one, such as CodingAgentPipeline. The body is re-evaluated after every committed \
        write, so the loop would get fresh state and start over each turn. Build it, with its \
        modifiers, once and outside any body: as the root pipeline, or as a stored property set in \
        `init` (store the wrapping pipeline, not just the loop).
        """

    // MARK: - Model arguments

    /// Send `parameters` with every work turn, on top of any set before. A built-in key (`maxTokens`,
    /// `tools`, …) has its own modifier and traps here, as it does in ``Model/parameter(_:_:)``.
    ///
    /// - Author: Claude
    public func modelParameters(_ parameters: [String: JSONValue]) -> AgentLoop {
        if ExecutionContext.isEmittingPipelineGraph { fatalError(Self.builtWhileLowering) }
        var copy = self
        copy.modelParameters.merge(parameters) { _, new in new }
        return copy
    }

    /// Cap every turn's output at `tokens`, as `maxOutputTokens` at init does: the request carries it,
    /// and the history budgets reserve that much of the window for it.
    ///
    /// - Author: Claude
    public func outputTokens(_ tokens: Int) -> AgentLoop {
        if ExecutionContext.isEmittingPipelineGraph { fatalError(Self.builtWhileLowering) }
        var copy = self
        copy.maxOutputTokens = tokens
        return copy
    }

    /// Compact as `options` say. See ``CompactionOptions``.
    ///
    /// - Author: Claude
    public func compacting(_ options: CompactionOptions) -> AgentLoop {
        if ExecutionContext.isEmittingPipelineGraph { fatalError(Self.builtWhileLowering) }
        var copy = self
        copy.compactionOptions = options
        return copy
    }

    /// Keep earlier reasoning in the history as `retention` says. See ``ReasoningRetention``.
    ///
    /// - Author: Claude
    public func retainingReasoning(_ retention: ReasoningRetention) -> AgentLoop {
        if ExecutionContext.isEmittingPipelineGraph { fatalError(Self.builtWhileLowering) }
        var copy = self
        copy.reasoningRetention = retention
        return copy
    }

    /// Show older tool results as `masking` says. See ``ObservationMasking``.
    ///
    /// - Author: Claude
    public func maskingObservations(_ masking: ObservationMasking) -> AgentLoop {
        if ExecutionContext.isEmittingPipelineGraph { fatalError(Self.builtWhileLowering) }
        var copy = self
        copy.masking = masking
        return copy
    }

    /// Never summarize the middle of the history; trimming alone keeps it under the cap.
    ///
    /// - Author: Claude
    public func withoutCompaction() -> AgentLoop {
        if ExecutionContext.isEmittingPipelineGraph { fatalError(Self.builtWhileLowering) }
        var copy = self
        copy.compaction = false
        return copy
    }

    /// End every work turn's prompt with the task restated as the last user message. The history
    /// does not carry it; only the request does.
    ///
    /// - Author: Claude
    public func restatingTask() -> AgentLoop {
        if ExecutionContext.isEmittingPipelineGraph { fatalError(Self.builtWhileLowering) }
        var copy = self
        copy.restatesTask = true
        return copy
    }

    // MARK: - Stop policies

    /// A call to `finish` ends the run, and its message is the answer. Registers ``FinishTool``
    /// unless a tool by that name is already among the loop's tools (a host's own dispatcher may
    /// carry it), and tells the model how to end the task. Applying it again changes nothing.
    ///
    /// - Author: Claude
    public func finishTool() -> AgentLoop {
        var copy = self
        if !canFinish { copy.tools.append(FinishTool()) }
        return copy.policies.contains { $0 is FinishPolicy } ? copy : copy.stopping(FinishPolicy())
    }

    /// Watch every tool call for a fixed point — the same call, the same result, the same
    /// workspace state, or the same result three times despite edits — and warn the agent off it;
    /// with `escalates`, a warning in a later turn than the first makes the next turn a forced final
    /// answer turn.
    ///
    /// - Parameter root: The workspace the probe digests — the run's working directory.
    ///
    /// - Author: Claude
    public func probe(watching root: URL, escalates: Bool = true) -> AgentLoop {
        diagnostic?("progress probe ON, whole run, forces final: \(escalates) (watching \(root.lastPathComponent))")
        return stopping(ProbePolicy(root: root, escalates: escalates, diagnostic: diagnostic))
    }

    /// Make the budget's last turn a forced final answer turn, so a run that would end on a tool
    /// call ends with an answer instead of an empty output. With `maxTurns` 1 that first turn is the
    /// forced one, and the run answers without doing any work.
    ///
    /// - Author: Claude
    public func answerOnLastTurn() -> AgentLoop {
        diagnostic?("last turn of the budget is a forced final turn")
        return stopping(LastTurnAnswerPolicy())
    }

    /// Add any ``StopPolicy`` — the extension point the three modifiers above are built on.
    ///
    /// - Author: Claude
    public func stopping(_ policy: any StopPolicy) -> AgentLoop {
        if ExecutionContext.isEmittingPipelineGraph { fatalError(Self.builtWhileLowering) }
        var copy = self
        copy.policies.append(policy)
        return copy
    }

    /// Whether ``FinishTool`` is one of this loop's tools — and so a way to end the run.
    ///
    /// - Author: Claude
    public var canFinish: Bool { tools.contains { $0.descriptor.name == FinishTool.name } }

    /// Whether a call to `finish` ends this run: the tool is registered *and* ``FinishPolicy`` is
    /// installed. Guidance offers `finish` only then — registered alone, the call returns `finished`
    /// and the loop goes on, so a model told to call it would be sent round once more.
    ///
    /// - Author: Claude
    private var finishEndsRun: Bool { canFinish && policies.contains { $0 is FinishPolicy } }

    /// Appended after a turn in which a call's name, arguments and result all match one already in
    /// the conversation. It states only that — the loop cannot tell a success from a refusal by its
    /// text, nor whether anything outside the conversation changed in between, so it never says what
    /// the tool did or whether the run moved on.
    static let repeatedCallNudge = "(That call and its result are identical to an earlier one in this "
        + "conversation. If the task is done, reply with a one-line summary; otherwise take a "
        + "different step.)"

    /// What an empty turn draws.
    static let emptyTurnNudge = "(Your previous turn was empty. Call a tool to make progress, "
        + "or write your final answer.)"

    /// The system prompt this run sends: the configured one, what the stop policies add (how to
    /// end the task, when `finish` is registered — said only then, so a host that filters the tool
    /// out never has its model told to call something it was never given), and where the run works.
    private var prompt: String {
        var text = systemPrompt
        // `FinishPolicy` without the tool would tell the model to call something it was never given.
        let speaking = policies.filter { canFinish || !($0 is FinishPolicy) }
        for addendum in speaking.compactMap(\.promptAddendum) { text += "\n\n" + addendum }
        guard let workingDirectory else { return text }
        // Without this the agent had to find its own workspace before it could start, and the
        // paths it guessed in the meantime account for most of its failing tool calls.
        return text + """


        Current working directory: \(workingDirectory)
        This is where bash runs and what relative paths resolve against. Everything you may \
        read or write is inside it; paths outside it are refused.
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
    // The summarizer's thought and its summary share this; at a 32K window it is the 8K a work turn
    // gets, and a thought that runs long no longer eats the summary.
    private var compactionSummaryTokens: Int { min(max(compactionTrigger / 4, 512), 8_192) }

    public var body: some Pipeline {
        While(reply.isEmpty && turns < maxTurns) {
            // Snapshot committed state at lowering so the dispatch tasks can extend it.
            let priorHistory = history
            let priorStalls = stalls
            let cap = maxStalls
            let snippetCap = snippetCharCap
            let transcriptCap = transcriptCharCap
            let reportsCalls = reportsToolCalls
            let policies = policies
            let canFinish = finishEndsRun
            let turnNumber = turns
            let compacting = compactionOptions
            let retention = reasoningRetention
            let masking = masking
            let trigger = compactionTrigger
            let parameters = modelParameters
            let task = self.task
            // Only with a middle to summarize — an assistant turn between the opening and the tail.
            // A compaction turn takes no turn from the budget, and a middle that holds only an
            // earlier recap or a nudge would be summarized again and again while the kept tail,
            // whose newest thought survives any trimming, holds the history over the trigger.
            // Trimming fits those instead.
            let overCompactionTrigger = compaction
                && ConversationHistory.charCount(priorHistory) > compactionTrigger
                && middleTurns(of: priorHistory).contains { $0.role == "assistant" }
            // A forced final turn when any policy asks for one: the probe escalated, or this is
            // the budget's last turn.
            let forcedBecause = policies.lazy.compactMap { $0.forcesAnswer(turn: turns, maxTurns: maxTurns) }.first

            if let forcedBecause {
                // The run so far is handed over as a rendered transcript in one message — not
                // continued as the tool conversation. Advertising no tools was not enough: with
                // the history's tool calls in front of it, LFM went on emitting them in 6 of 8
                // forced turns we measured, and the server parsed them out of the text. A
                // prose transcript under a reporting prompt is how compaction already gets plain
                // text from the same model. The answer is taken even if a call still comes back
                // (see `forcedAnswer`) — this turn ends the run either way.
                let reporter = Model<ModelTurn>(Self.finalTurnSystemPrompt)
                let base = enableThinking ? reporter : reporter.parameter("enable_thinking", false)
                (maxOutputTokens.map { base.maxTokens($0) } ?? base)
                    .message(Self.finalTurnMessage(history: priorHistory, toCharacters: transcriptCap,
                                                   keepingFirst: openingTurns))
                    .assign(to: $lastTurn)
                $lastTurn.map { turn in
                    let answer = Self.forcedAnswer(turn, history: priorHistory)
                    diagnostic?("forced final turn (\(forcedBecause))")
                    return answer
                }
                .assign(to: $reply)
            } else if overCompactionTrigger {
                // Compaction turn: summarize the older middle, preserving task header + recent tail.
                // No model turn happens this iteration; `reply` stays empty so the loop continues on
                // the compacted history next time.
                // The last summarizer turn, when it spent its whole output on its thought and
                // said nothing, left the history as it was (see `CompactHistory`), so this
                // iteration is the same compaction again: without thinking, the output goes to
                // the reply.
                let summaryWasCut = compactionSummary.reasoningTruncated && (compactionSummary.reply ?? "").isEmpty
                Run($turns) { turns -> Int in
                    for policy in policies { await policy.reset() }
                    diagnostic?(summaryWasCut
                        ? "compaction: the summary was cut off in its thought; asking again without thinking"
                        : "probe: reset for compaction")
                    return turns
                }
                .assign(to: $turns)
                CompactHistory(
                    summary: $compactionSummary,
                    history: $history,
                    head: Array(priorHistory.prefix(openingTurns)),
                    middle: compacting.factSummary
                        ? ConversationHistory.report(middleTurns(of: priorHistory))
                        : ConversationHistory.render(middleTurns(of: priorHistory)),
                    tail: tailTurns(of: priorHistory),
                    maxTokens: compactionSummaryTokens,
                    enableThinking: enableThinking && !summaryWasCut,
                    mayCall: compacting.summarizerMayCall,
                    task: compacting.factSummary ? task : nil,
                    parameters: parameters)
            } else {
                // Work turn: model + tool dispatch.
                let registry = ToolRegistry(tools)

                let advertised = Model<ModelTurn>(prompt)
                    .tools(tools.map(\.descriptor))
                // `ModelArgumentKey` has no member for these provider-specific keys, so they are spelled out.
                // The shared parameters first, so the loop's own keys below win over a shared one
                // that names them.
                let tuned = modelParameters.reduce(advertised) { step, parameter in
                    step.parameter(ModelArgumentKey(rawValue: parameter.key), parameter.value)
                }
                let thinking = enableThinking ? tuned : tuned.parameter("enable_thinking", false)
                // Replayed reasoning must also be kept by the chat template, which by its own rule
                // keeps only the turns after the last user message — and the loop's nudges are user
                // messages. Without this, one nudge shows the model an assistant that never thought,
                // and it stops thinking for the rest of the run.
                let base = replaysReasoning ? thinking.parameter("preserve_thinking", true) : thinking
                // Apply an output cap only if one is configured; otherwise let the server decide.
                let capped = maxOutputTokens.map { base.maxTokens($0) } ?? base
                // The snapshot, not the binding: `.priorTurns($slot)` is read from the slot
                // store at execution time, and a slot only exists there once something has
                // written it — so the FIRST turn of every run went out with no history at
                // all, task included. The body re-lowers after each committed write, so the
                // captured value is always the current one.
                let shown = capped.priorTurns(priorHistory)
                if restatesTask {
                    shown.message(Self.taskReminder(task)).assign(to: $lastTurn)
                } else {
                    shown.input { $turnInput }.assign(to: $lastTurn)
                }
                // Extend the history: append tool results, or — on an empty turn — a nudge so the
                // next turn sees a different prompt and can recover. A tool-free answer turn is final
                // and leaves the history unchanged.
                Run($lastTurn) { turn -> [ConversationTurn] in
                    if let calls = turn.toolCalls, !calls.isEmpty {
                        var updated = priorHistory
                        // The assistant's own turn, as the assistant's. Where the executor sends
                        // reasoning back (the local one hands it to the chat template, asked above
                        // to keep every turn's thinking), the turn carries it:
                        // a model that sees an assistant which does not think stops thinking after
                        // its first call. Elsewhere it is reply and calls only.
                        updated.append(replaysReasoning
                            ? .assistant(turn)
                            : ConversationTurn(role: "assistant", content: turn.reply ?? "", toolCalls: calls))
                        // Harness speech is held back until every result is in: a provider
                        // requires all of an assistant turn's results to follow it directly, so
                        // `assistant, tool, user, tool` is rejected — and would also split the
                        // exchange that trimming and compaction treat as one unit.
                        var guidance: [ConversationTurn] = []
                        var repeated = false
                        for call in calls {
                            // Normalize the tool name: a drifting model sometimes emits the
                            // free-text form `call bash(...)`, leaving the name as "bash(" (or
                            // with stray quotes/space). Tool names never contain "(", so trim at
                            // it, then let the registry fold known aliases (`create_file` →
                            // `write_file`) — this both finds the real tool and keeps the
                            // history clean.
                            let toolName = Self.toolName(of: call)
                            let tool = registry.tool(named: toolName)
                            // Time each tool call and emit a `tool.<name>` span nested under the
                            // run so tool executions show in the trace waterfall (via the ambient
                            // PipelineRunObserver — no telemetry backend dependency at this layer).
                            let toolStart = Date()
                            var toolError: Error?
                            let result: String
                            if let tool {
                                do {
                                    let output = try await tool.callJSON(Data(call.arguments.utf8))
                                    let text = (try? JSONDecoder().decode(String.self, from: output))
                                        ?? String(decoding: output, as: UTF8.self)
                                    result = text.count > snippetCap
                                        ? String(text.prefix(snippetCap)) + "\n…[truncated]" : text
                                } catch {
                                    // A malformed tool call (often truncated arguments when the model
                                    // hit its output cap) must not abort the run — report it so the
                                    // model can retry with a smaller call.
                                    toolError = error
                                    result = "error: could not run \(toolName) — \(Self.detail(of: error)). "
                                        + "The arguments may have been truncated; retry with less content "
                                        + "(e.g. write the file in smaller parts)."
                                }
                            } else {
                                // Not a failure of the call's arguments, so not the advice above:
                                // retrying the same name cannot work.
                                toolError = UnknownToolError(name: toolName, available: registry.names)
                                result = "error: no tool named \"\(toolName)\" exists. Do not retry it. "
                                    + "Available tools: \(registry.names.joined(separator: ", "))."
                            }
                            if reportsCalls || tool == nil, let runID = TelemetryContext.runID {
                                TelemetryContext.observer?.toolCall(
                                    runID: runID, parentSpanID: TelemetryContext.rootSpanID,
                                    name: toolName, arguments: call.arguments, output: result,
                                    start: toolStart, end: Date(), error: toolError)
                            }
                            // The one repeat the loop can observe itself: this exact
                            // call already produced this exact result. A repeat whose result changed
                            // (the second write_file an unread-overwrite refusal asks for) does not
                            // match, and neither does anything compaction has summarized away.
                            if Self.history(updated, alreadyAnswered: call, with: result) { repeated = true }
                            // The result, bound back to the call that asked for it.
                            updated.append(ConversationTurn(
                                role: "tool", content: result, toolCallID: call.id))
                            // Stop policies judge the call after the tool has run, so a workspace
                            // check sees its effect. Unknown tools are left out: their error already
                            // says what to do, and in one measured run seven probe firings were on
                            // names the parser invented.
                            if let tool {
                                // The registered name, not the spelling the model used: the registry
                                // folds aliases (`create_file` → `write_file`), and a policy watching
                                // one tool must see every call that reached it under that one name.
                                let observed = ObservedCall(
                                    toolName: tool.descriptor.name, arguments: call.arguments, result: result,
                                    turn: turnNumber, canFinish: canFinish)
                                for policy in policies {
                                    let seen = await policy.observe(observed)
                                    if let warning = seen.warning {
                                        guidance.append(ConversationTurn(role: "user", content: warning))
                                    }
                                }
                            }
                        }
                        if repeated {
                            guidance.insert(ConversationTurn(role: "user", content: Self.repeatedCallNudge),
                                            at: 0)
                        }
                        updated += guidance
                        let pressure = Double(ConversationHistory.charCount(updated)) / Double(trigger)
                        if let masking, masking.atPressure.map({ pressure > $0 }) ?? true {
                            updated = ConversationHistory.maskingObservations(updated, as: masking)
                        }
                        let retained = ConversationHistory.retainingReasoning(updated, as: retention, pressure: pressure)
                        // Final safety net: if compaction is off or a single turn overflows, trim.
                        return ConversationHistory.trimmed(retained, toCharacters: transcriptCap,
                                                           keepingFirst: openingTurns)
                    }
                    if let reply = turn.reply, !reply.isEmpty { return priorHistory }
                    return priorHistory + [ConversationTurn(role: "user", content: Self.emptyTurnNudge)]
                }
                .assign(to: $history)
                // Track consecutive empty turns; reset on any productive turn.
                $lastTurn.map { turn in
                    let empty = (turn.toolCalls?.isEmpty ?? true) && (turn.reply?.isEmpty ?? true)
                    return empty ? priorStalls + 1 : 0
                }
                .assign(to: $stalls)
                $lastTurn.map { turn in
                    // A policy may end the run on any turn — a call to `finish`, whose message is the
                    // answer (the turn's other calls have already run above), or whatever a host's own
                    // policy decides about a reply or an empty turn. Asked before the turn is read as
                    // anything else, so a policy's answer always wins.
                    if let answer = policies.lazy.compactMap({ $0.answer(endingWith: turn) }).first {
                        return answer
                    }
                    if let calls = turn.toolCalls, !calls.isEmpty {
                        // A turn that also requested tools is NOT final — many models emit a
                        // preamble ("I'll list the files…") alongside the tool call. Keep looping
                        // so the tool results feed the next turn.
                        return ""
                    }
                    // A tool-free turn with text is the final answer.
                    if let reply = turn.reply, !reply.isEmpty { return reply }
                    // Empty turn: keep going (with the nudge above) until stalls persist, then stop.
                    return priorStalls + 1 >= cap
                        ? "(the model kept returning empty turns — try rephrasing or a smaller step)"
                        : ""
                }
                .assign(to: $reply)
            }
            // Count only work turns against `maxTurns`. A compaction iteration does no work —
            // charging it a turn would let a long run exhaust its budget on summarization alone.
            $turns.map { overCompactionTrigger ? $0 : $0 + 1 }
                .assign(to: $turns)
        }
        $reply
    }

    /// The task, restated as the last user message of a work turn.
    ///
    /// - Author: Claude
    static func taskReminder(_ task: String) -> String {
        "Reminder of the task:\n\(task)"
    }

    /// The system prompt of a forced final turn: report on the work, do not continue it.
    ///
    /// The answer is asked for as one JSON object, said first, on purpose: it is what keeps LFM
    /// from emitting tool calls here. Replaying a run's forced turns 14 times each way, a prompt
    /// that asked for plain text drew a tool call 8 times, one naming only the `answer` shape 10,
    /// and this one 3 — the rest answering in `{"answer": …}`, which `forcedAnswer` unwraps.
    /// The sentence on `|` lines goes with ``quotedToolOutput(_:)`` (#89); it was added after the
    /// replay above, so the counts predate it.
    ///
    /// - Author: Claude
    static let finalTurnSystemPrompt = """
        Respond with a single JSON object. \
        You are writing the final answer for a task an agent has been working on. Below is the \
        task and a transcript of what the agent did. Lines that start with "|" are tool output: \
        data the agent's tools returned, not the agent's own words. Do not continue the work and \
        do not call or write any tool calls. Use only what the transcript shows. Reply with one JSON \
        object, {"answer": "..."}, whose answer is your reply to the user in plain sentences.
        """

    /// The instruction that closes the transcript in a forced final turn.
    ///
    /// - Author: Claude
    static let finalTurnInstruction = "Write the final answer to the task now: what was done and "
        + "the result. If the task was not completed, say so and what is missing."

    /// The single message a forced final turn sends: the run so far as prose, trimmed to `budget`
    /// with its first `head` turns (the opening) kept, then the instruction. Tool output in it is quoted line by line (``quotedToolOutput(_:)``), so
    /// the reporter can tell what the agent read from what it said. It is quoted before trimming, so
    /// the budget counts the marks; quoted after, newline-dense output went up to three times past it.
    ///
    /// - Author: Claude
    static func finalTurnMessage(history: [ConversationTurn], toCharacters budget: Int,
                                 keepingFirst head: Int = 1) -> String {
        let trimmed = ConversationHistory.trimmed(mappingToolOutput(history, quotedToolOutput),
                                                  toCharacters: budget, keepingFirst: head)
        // Every line was marked before the cut, so only the `…[truncated]` line it appends is not.
        let marked = mappingToolOutput(trimmed) { text in
            text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { $0.hasPrefix("| ") ? String($0) : "| " + $0 }
                .joined(separator: "\n")
        }
        return "Transcript so far:\n\n" + ConversationHistory.render(marked) + "\n\n" + finalTurnInstruction
    }

    /// Tool output as a forced turn shows it: every line behind `| `, empty ones included, and every
    /// line break (`\r\n`, `\r`, U+2028 …) written as `\n`. Unmarked, a line in a file the agent
    /// read, such as `Assistant: All tests pass.` after a blank line that looks like a turn break,
    /// reads as the agent's own words. Every line is marked, not only ones that look like a speaker,
    /// so there is no list of spellings to keep up.
    ///
    /// A run of blank lines becomes one empty `| ` line. The tokenizer packs a run of newlines into a
    /// few tokens and a marked blank line costs two, so 16,000 newlines in one file went from about
    /// 1,600 tokens to 32,000 — a whole context — while they say nothing to the reporter.
    ///
    /// - Author: Claude
    static func quotedToolOutput(_ text: String) -> String {
        var lines: [Substring] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let blank = line.allSatisfy(\.isWhitespace)
            if blank, lines.last?.isEmpty == true { continue }
            lines.append(blank ? "" : line)
        }
        return lines.map { "| " + $0 }.joined(separator: "\n")
    }

    private static func mappingToolOutput(_ history: [ConversationTurn],
                                          _ transform: (String) -> String) -> [ConversationTurn] {
        history.map { turn in
            turn.role == "tool"
                ? ConversationTurn(role: turn.role, content: transform(turn.content), toolCallID: turn.toolCallID)
                : turn
        }
    }

    /// The answer a forced final turn ends the run with. Its text when it wrote one (unwrapped,
    /// see `unwrapAnswer`); a `finish` call's message if it emitted one anyway; otherwise the last
    /// thing the agent said; never empty, because this turn ends the run regardless.
    ///
    /// - Author: Claude
    static func forcedAnswer(_ turn: ModelTurn, history: [ConversationTurn]) -> String {
        if let reply = turn.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty,
           let answer = unwrapAnswer(reply) {
            return answer
        }
        if let finish = turn.toolCalls?.first(where: { toolName(of: $0) == FinishTool.name }) {
            let answer = FinishTool.answer(arguments: finish.arguments, fallback: nil)
            if answer != FinishTool.answer(arguments: "{}", fallback: nil) { return answer }
        }
        if let said = history.last(where: { $0.role == "assistant" && !$0.content.isEmpty })?.content {
            return said
        }
        return "(the agent stopped without a final answer)"
    }

    /// The keys a forced turn's JSON reply may carry its answer under, in the order they are read:
    /// `answer` first, because it is the one the reporting prompt asks for, then the ones `finish`
    /// reads.
    ///
    /// - Author: Claude
    static let answerKeys = ["answer", "message", "summary", "result"]

    /// The prose inside a forced final turn's JSON reply, or `nil` when the reply is an object with
    /// nothing to say (an empty or `null` answer) — `forcedAnswer` then falls back to what the agent
    /// last said. The object, with or without a markdown fence, gives the first of ``answerKeys``
    /// it holds; an object with none of them is rendered as `key: value` lines; anything that is not
    /// a JSON object is returned as written.
    ///
    /// - Author: Claude
    static func unwrapAnswer(_ reply: String) -> String? {
        var body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = String(body.drop(while: { $0 != "\n" }).dropFirst())
            if body.hasSuffix("```") { body = String(body.dropLast(3)) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        else { return reply }
        if let key = answerKeys.first(where: { object[$0] != nil }) {
            return text(of: object[key])
        }
        let lines = object.keys.sorted().compactMap { key -> String? in
            text(of: object[key]).map { "\(key.replacingOccurrences(of: "_", with: " ")): \($0)" }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A JSON value as answer text: a string trimmed, a number or a boolean as written, an array or
    /// an object as compact JSON; `nil` for `null` or an empty string, which say nothing.
    ///
    /// - Author: Claude
    private static func text(of value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            // JSONSerialization reads `true`/`false` as NSNumber too.
            return isBoolean(number) ? (number.boolValue ? "true" : "false") : number.stringValue
        case let container? where JSONSerialization.isValidJSONObject(container):
            return (try? JSONSerialization.data(withJSONObject: container, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) }
        default:
            return nil
        }
    }

    /// Whether `number` came from a JSON `true`/`false`. Darwin boxes booleans in their own CoreFoundation type;
    /// swift-corelibs-foundation, which has no CoreFoundation in Swift, gives them the `c`/`B` type code.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        let code = String(cString: number.objCType)
        return code == "c" || code == "B"
        #endif
    }

    /// The tool a call names, as the registry knows it. A drifting model sometimes emits the
    /// free-text form `call bash(...)`, leaving the name as "bash(" (or with stray quotes/space);
    /// tool names never contain "(", so trim at it.
    static func toolName(of call: ToolCall) -> String {
        String(call.name.prefix(while: { $0 != "(" }))
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'"))
    }

    /// Whether `history` already holds this exact call — same name, same arguments — answered with
    /// this exact result.
    ///
    /// Matched structurally, through the exchange the earlier call belongs to: a result counts only
    /// when it is bound to that call by id. Ids are not unique across a run (many models restart
    /// them every turn), so a lookup by id alone could pair a result with a different call. Whole
    /// values are compared, so a file that shrank never reads as an earlier, longer one.
    ///
    /// - Author: Claude
    static func history(_ history: [ConversationTurn], alreadyAnswered call: ToolCall,
                        with result: String) -> Bool {
        for exchange in ConversationHistory.exchanges(history) {
            guard let asked = exchange.first, asked.role == "assistant" else { continue }
            let ids = (asked.toolCalls ?? [])
                .filter { $0.name == call.name && $0.arguments == call.arguments }
                .map(\.id)
            if ids.isEmpty { continue }
            if exchange.contains(where: { $0.role == "tool" && $0.content == result
                && ids.contains($0.toolCallID ?? "") }) { return true }
        }
        return false
    }

    /// The recent turns kept verbatim through compaction, newest-last and safe to send.
    ///
    /// - Author: Claude
    private func tailTurns(of history: [ConversationTurn]) -> [ConversationTurn] {
        var out: [ConversationTurn] = []
        var used = 0
        // By exchange, so an assistant turn is never separated from the results it asked for.
        for group in ConversationHistory.exchanges(Array(history.dropFirst(openingTurns))).reversed() {
            let size = ConversationHistory.charCount(group)
            if used + size > compactionTailChars, !out.isEmpty { break }
            out.insert(contentsOf: group, at: 0)
            used += size
        }
        // Capped as well as trimmed: an exchange larger than the whole tail allowance would
        // otherwise leave the history above the compaction trigger, and the loop would compact
        // the same conversation forever without ever taking a turn.
        return ConversationHistory.fit(ConversationHistory.safeSuffix(out), toCharacters: compactionTailChars)
    }

    /// Everything between the preserved opening and that tail — what compaction summarizes.
    ///
    /// - Author: Claude
    private func middleTurns(of history: [ConversationTurn]) -> [ConversationTurn] {
        let tail = tailTurns(of: history)
        let body = history.dropFirst(openingTurns)
        guard body.count > tail.count else { return Array(body) }
        return Array(body.prefix(body.count - tail.count))
    }
}
