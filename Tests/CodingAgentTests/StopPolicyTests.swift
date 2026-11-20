//
//  StopPolicyTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import ComposablePipelines
@testable import CodingAgent
@testable import ComposablePipelines

/// Each stop policy on its own: what it adds, when it ends the run, when it forces an answer.
///
/// - Author: Claude
final class StopPolicyTests: XCTestCase {

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A call to `finish` ends the run with its message; the reply is the fallback; any other turn
    /// keeps the run going.
    func testFinish_endsTheRunOnItsCall() {
        let policy = FinishPolicy()
        XCTAssertNotNil(policy.promptAddendum)
        let finish = ModelTurn(toolCalls: [
            ToolCall(id: "1", name: "write_file", arguments: "{}"),
            ToolCall(id: "2", name: "finish", arguments: #"{"message":"Done."}"#),
        ])
        XCTAssertEqual(policy.answer(endingWith: finish), "Done.")
        let bare = ModelTurn(reply: "Wrote it.", toolCalls: [ToolCall(id: "1", name: "finish", arguments: "{}")])
        XCTAssertEqual(policy.answer(endingWith: bare), "Wrote it.", "the turn's text stands in for a missing message")
        let work = ModelTurn(toolCalls: [ToolCall(id: "1", name: "bash", arguments: "{}")])
        XCTAssertNil(policy.answer(endingWith: work))
        XCTAssertNil(policy.forcesAnswer(turn: 14, maxTurns: 15), "finish never forces a turn")
    }

    /// The guard forces exactly the budget's last turn.
    func testLastTurnAnswer_forcesOnlyTheLastTurn() {
        let policy = LastTurnAnswerPolicy()
        XCTAssertNil(policy.forcesAnswer(turn: 0, maxTurns: 3))
        XCTAssertNil(policy.forcesAnswer(turn: 1, maxTurns: 3))
        XCTAssertEqual(policy.forcesAnswer(turn: 2, maxTurns: 3), "last turn of the budget")
        XCTAssertNil(policy.promptAddendum)
    }

    /// The probe warns on the first repeat and, when it escalates, forces the next turn after a
    /// warning in a later turn — announced once, and kept across a compaction.
    func testProbe_escalatesOnItsSecondWarning() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let notes = NotesBox()
        let policy = ProbePolicy(root: root, escalates: true, diagnostic: { notes.append($0) })

        let first = await policy.observe(ObservedCall(toolName: "list_dir", arguments: "{}", result: "a.txt", turn: 0))
        XCTAssertNil(first.warning)
        let second = await policy.observe(ObservedCall(toolName: "list_dir", arguments: "{}", result: "a.txt", turn: 1))
        XCTAssertNotNil(second.warning)
        XCTAssertNil(policy.forcesAnswer(turn: 2, maxTurns: 10), "one warning is advice, not an action")
        let third = await policy.observe(ObservedCall(toolName: "list_dir", arguments: "{}", result: "a.txt", turn: 2))
        XCTAssertNotNil(third.warning)
        XCTAssertEqual(policy.forcesAnswer(turn: 3, maxTurns: 10), "probe escalated")
        _ = await policy.observe(ObservedCall(toolName: "list_dir", arguments: "{}", result: "a.txt", turn: 3))
        XCTAssertEqual(notes.all.filter { $0.contains("warned again in a later turn") }.count, 1, "announced once")

        await policy.reset()
        XCTAssertEqual(policy.forcesAnswer(turn: 3, maxTurns: 10), "probe escalated",
                       "compaction forgets comparisons, not that the agent was warned twice")
    }

    /// Two warnings drawn by one turn are one warning: the model has seen neither, so the first is
    /// still advice. A warning in a later turn is what escalates.
    ///
    /// - Author: Claude
    func testProbe_twoWarningsInOneTurnDoNotEscalate() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let policy = ProbePolicy(root: root, escalates: true)
        _ = await policy.observe(ObservedCall(toolName: "list_dir", arguments: "{}", result: "a.txt", turn: 0))
        _ = await policy.observe(ObservedCall(toolName: "bash", arguments: "{}", result: "ok", turn: 0))
        // Turn 1 repeats both earlier calls: two warnings at once.
        let repeatList = await policy.observe(ObservedCall(toolName: "list_dir", arguments: "{}", result: "a.txt", turn: 1))
        let repeatBash = await policy.observe(ObservedCall(toolName: "bash", arguments: "{}", result: "ok", turn: 1))
        XCTAssertNotNil(repeatList.warning)
        XCTAssertNotNil(repeatBash.warning)
        XCTAssertNil(policy.forcesAnswer(turn: 2, maxTurns: 10), "the model has not seen either warning yet")

        _ = await policy.observe(ObservedCall(toolName: "list_dir", arguments: "{}", result: "a.txt", turn: 2))
        XCTAssertEqual(policy.forcesAnswer(turn: 3, maxTurns: 10), "probe escalated")
    }

    /// Without escalation the probe only advises.
    func testProbe_withoutEscalationNeverForces() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let policy = ProbePolicy(root: root, escalates: false)
        for _ in 0..<4 { _ = await policy.observe(ObservedCall(toolName: "bash", arguments: #"{"command":"true"}"#, result: "ok")) }
        XCTAssertNil(policy.forcesAnswer(turn: 4, maxTurns: 10))
    }

    /// The warning names `finish` exactly when the run has it — decided per call, so the order in
    /// which `.probe(…)` and `.finishTool()` were applied does not matter.
    func testProbe_warningSaysHowToFinish() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let policy = ProbePolicy(root: root, escalates: false)
        let call = ObservedCall(toolName: "bash", arguments: "{}", result: "ok", canFinish: true)
        _ = await policy.observe(call)
        let withFinish = await policy.observe(call).warning
        XCTAssertTrue(withFinish?.contains("call `finish` with your final answer now") == true, withFinish ?? "nil")
        var noFinish = call
        noFinish.canFinish = false
        let without = await policy.observe(noFinish).warning
        XCTAssertTrue(without?.contains("reply with your final answer now") == true, without ?? "nil")
    }
}

/// Collects diagnostic lines from a `@Sendable` hook.
///
/// - Author: Claude
private final class NotesBox: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
