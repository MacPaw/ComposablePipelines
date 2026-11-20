//
//  StopPolicy.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST
import PipelineDSL

/// A rule for when a tool-calling loop stops — and that it stops with an answer.
///
/// The loop consults its policies at fixed points and never lets them do anything else. The
/// invariant: **a policy can add a line to the prompt, add guidance after a tool call, end the run
/// with an answer, or make the next turn a forced final answer turn** — it never edits the history
/// or a tool's result. Several policies combine by taking the strongest outcome: any answer ends the
/// run, any forcing reason forces the turn, every warning is shown.
///
/// Stateful policies (the progress probe) must be created once by the host and passed in, never
/// built inside a pipeline's `body`: the DSL re-evaluates `body` after every committed write, so a
/// policy made there would start from nothing each turn.
///
/// - Author: Claude
public protocol StopPolicy: Sendable {
    /// A paragraph the system prompt gains while this policy is active.
    var promptAddendum: String? { get }

    /// The run's answer when `turn` ends it, or `nil` to keep going. Called for every turn — one
    /// with tool calls (after they have run), a reply, or an empty turn — before the loop reads the
    /// turn itself, so an answer here always wins.
    func answer(endingWith turn: ModelTurn) -> String?

    /// Judge one completed call to a known tool. Called after the tool ran, so any workspace check
    /// sees its effect.
    func observe(_ call: ObservedCall) async -> StopObservation

    /// Why the turn about to be taken must be a forced final answer turn, or `nil`. `turn` counts
    /// the work turns already taken. Synchronous: the loop asks while it lowers the next turn.
    func forcesAnswer(turn: Int, maxTurns: Int) -> String?

    /// The history was compacted; forget comparisons that refer to turns no longer in context.
    func reset() async
}

/// One completed tool call, as a policy sees it.
///
/// - Author: Claude
public struct ObservedCall: Sendable, Equatable {
    /// The tool's registered name.
    public var toolName: String
    /// The call's arguments, as the model sent them.
    public var arguments: String
    /// What the tool returned, as the model will read it.
    public var result: String
    /// Work turns already taken before the one that made this call.
    public var turn: Int
    /// Whether the run can be ended by calling `finish` — so guidance can say how to finish.
    public var canFinish: Bool

    public init(toolName: String, arguments: String, result: String, turn: Int = 0, canFinish: Bool = false) {
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.turn = turn
        self.canFinish = canFinish
    }
}

/// What a policy made of one tool call. A policy that wants its reasoning in the transcript logs
/// it itself (``ProbePolicy`` takes the run's diagnostic hook).
///
/// - Author: Claude
public struct StopObservation: Sendable, Equatable {
    /// Guidance for the model, appended after the turn's tool results; `nil` when there is none.
    public var warning: String?

    public init(warning: String? = nil) {
        self.warning = warning
    }

    /// Nothing to say.
    public static let quiet = StopObservation()
}

public extension StopPolicy {
    var promptAddendum: String? { nil }
    func answer(endingWith turn: ModelTurn) -> String? { nil }
    func observe(_ call: ObservedCall) async -> StopObservation { .quiet }
    func forcesAnswer(turn: Int, maxTurns: Int) -> String? { nil }
    func reset() async {}
}

/// A call to ``FinishTool`` ends the run, and its message is the answer.
///
/// The tool itself must be among the loop's tools: an unregistered `finish` is an unknown tool like
/// any other, and the prompt must not tell the model to call something it was never given.
///
/// - Author: Claude
struct FinishPolicy: StopPolicy {
    init() {}

    // Either way ends the run, and the prompt says so: naming `finish` as *the* way to end pushed a
    // small model to call it on small talk, against a system prompt that tells it to just answer.
    var promptAddendum: String? {
        """
        When the task is done, give your answer: reply without calling a tool, or call `finish` \
        with the answer — either ends the task. Do not end it while work remains.
        """
    }

    /// The other calls of the turn have already run; the reply text is the fallback when `finish`
    /// carries no message.
    func answer(endingWith turn: ModelTurn) -> String? {
        guard let finish = turn.toolCalls?.first(where: {
            AgentLoop.toolName(of: $0) == FinishTool.name
        }) else { return nil }
        return FinishTool.answer(arguments: finish.arguments, fallback: turn.reply)
    }
}

/// The budget's last turn is a forced final answer turn, so a run that would end on a tool call
/// ends with an answer instead of an empty output. With a budget of one turn that turn is the
/// forced one, so the run does no work at all.
///
/// - Author: Claude
struct LastTurnAnswerPolicy: StopPolicy {
    init() {}

    func forcesAnswer(turn: Int, maxTurns: Int) -> String? {
        turn >= maxTurns - 1 ? "last turn of the budget" : nil
    }
}

/// Watches every tool call with a ``ProgressProbe`` and warns the agent off a fixed point; with
/// `escalates`, a warning in a later turn than the first one makes the next turn a forced final
/// answer turn. A warning is advice the model can ignore — measured, about half of the warnings
/// were followed by the identical call — so the second one becomes an action. Counted per turn, not
/// per call: a turn that repeats two earlier calls draws two warnings at once, and the model has not
/// yet seen either of them.
///
/// A reference type: the probe's memory must outlive every re-lowering of the loop's body, so the
/// host creates it once per run and passes the same instance in. Once per *run*: nothing here is
/// cleared when a run ends, so a second run of the same value starts already escalated.
///
/// - Author: Claude
final class ProbePolicy: StopPolicy, @unchecked Sendable {
    private let probe: ProgressProbe
    private let escalates: Bool
    private let diagnostic: (@Sendable (String) -> Void)?
    /// The turn of the first warning, and whether a later turn has been warned too; read
    /// synchronously while the next turn is lowered. Guarded by `lock` (the only mutable state of an
    /// otherwise immutable, Sendable class).
    private var firstWarnedTurn: Int?
    private var escalated = false
    private let lock = NSLock()

    /// - Parameters:
    ///   - root: The workspace the probe digests — the run's working directory.
    ///   - escalates: Turn a warning in a later turn than the first into a forced final answer turn.
    ///   - diagnostic: Where probe notes go, for the transcript.
    init(root: URL, escalates: Bool, diagnostic: (@Sendable (String) -> Void)? = nil) {
        self.probe = ProgressProbe(root: root)
        self.escalates = escalates
        self.diagnostic = diagnostic
    }

    /// The warning tells the model how to finish — "call `finish` …" when the run has that tool,
    /// otherwise to reply with its answer.
    func observe(_ call: ObservedCall) async -> StopObservation {
        let seen = await probe.observe(
            call: "\(call.toolName)(\(call.arguments))", result: call.result,
            endInstruction: call.canFinish ? "call `finish` with your final answer now"
                                           : "reply with your final answer now")
        diagnostic?("probe: \(seen.note)")
        if escalates, seen.warning != nil {
            let first = lock.withLock { () -> Bool in
                guard let earlier = firstWarnedTurn else { firstWarnedTurn = call.turn; return false }
                guard earlier < call.turn, !escalated else { return false }
                escalated = true
                return true
            }
            if first { diagnostic?("probe: warned again in a later turn — next turn is a forced final turn") }
        }
        return StopObservation(warning: seen.warning)
    }

    func forcesAnswer(turn: Int, maxTurns: Int) -> String? {
        lock.withLock { escalated } ? "probe escalated" : nil
    }

    func reset() async {
        await probe.reset()
    }
}
