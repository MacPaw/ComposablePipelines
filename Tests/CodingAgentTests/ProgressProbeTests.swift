//
//  ProgressProbeTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
@testable import CodingAgent
@testable import ComposablePipelines

/// The probe's whole point is that repetition is allowed and stagnation is not, so the cases
/// that must stay silent matter as much as the one that must speak.
final class ProgressProbeTests: XCTestCase {

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to root: URL, named name: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Write a file and stamp it with an explicit modification time.
    ///
    /// Two writes inside one unit test land in the same wall-clock second, which is not what
    /// happens between two tool calls — those are an inference round-trip apart. Without the
    /// explicit stamp a digest keyed on whole-second mtime looks stable here and drifts in
    /// production, so the test would pass against exactly the bug it is meant to pin.
    ///
    /// - Author: Claude
    private func write(_ text: String, to root: URL, named name: String,
                       modified: Date) throws {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: url.path)
    }

    func testFlagsACallThatChangesNeitherTheWorldNorWhatIsKnown() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)

        // `mkdir -p` on a directory that already exists: exit 0, no output, nothing moves.
        let call = #"bash({"command":"mkdir -p out"})"#
        var warning = await probe.observe(call: call, result: "exit 0\n").warning
        XCTAssertNil(warning, "the first call cannot be a fixed point — there is nothing to compare")
        warning = await probe.observe(call: call, result: "exit 0\n").warning
        XCTAssertTrue(warning?.contains("already made this exact call") == true, warning ?? "nil")
    }

    /// Rewriting a file with the bytes it already holds is not progress.
    ///
    /// The digest was built from path, size and modification time, so a no-op rewrite read as the
    /// world moving and the probe stayed silent through the commonest loop there is. Measured on
    /// `dijkstra-shortest-paths`: 18 of 30 calls were `write_file`, in streaks of up to five
    /// identical writes, each returning `wrote solution.py (27 bytes)` byte for byte.
    ///
    /// - Author: Claude
    func testARewriteWithTheSameBytesIsAFixedPoint() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)

        let call = #"write_file({"path":"solution.py","content":"def f(): pass"})"#
        let result = "wrote solution.py (13 bytes)"
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        try write("def f(): pass", to: root, named: "solution.py", modified: start)
        _ = await probe.observe(call: call, result: result)
        try write("def f(): pass", to: root, named: "solution.py",
                  modified: start.addingTimeInterval(37))
        let warning = await probe.observe(call: call, result: result).warning
        XCTAssertNotNil(warning, "same call, same result, same bytes — only the timestamp moved")
    }

    /// The counterpart: a rewrite that genuinely changes the file is progress.
    ///
    /// - Author: Claude
    func testARewriteWithDifferentBytesIsProgress() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)

        let call = #"write_file({"path":"solution.py","content":"…"})"#
        let result = "wrote solution.py"
        try write("first attempt", to: root, named: "solution.py")
        _ = await probe.observe(call: call, result: result)
        try write("second attempt", to: root, named: "solution.py")
        let warning = await probe.observe(call: call, result: result).warning
        XCTAssertNil(warning, "the file holds something else now, so the agent got somewhere")
    }

    func testStaysSilentWhenTheWorkspaceMoved() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)

        // Re-running the same build after an edit is the canonical legitimate repeat.
        let build = #"bash({"command":"make"})"#
        _ = await probe.observe(call: build, result: "ok").warning
        try write("edited once", to: root, named: "a.c")
        let warning = await probe.observe(call: build, result: "ok").warning
        XCTAssertNil(warning, "the world changed between the calls, so the repeat is progress")
    }

    func testStaysSilentWhenTheAnswerChanged() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)

        // Polling something that is genuinely moving: the call repeats, the answer does not.
        let poll = #"bash({"command":"curl -s http://localhost/status"})"#
        _ = await probe.observe(call: poll, result: "pending").warning
        _ = await probe.observe(call: poll, result: "running").warning
        let warning = await probe.observe(call: poll, result: "done").warning
        XCTAssertNil(warning, "a repeat that returns something new is how you learn")
    }

    func testAFailureRepeatedIdenticallyIsAlsoAFixedPoint() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)

        // Observed for real: `rm` on a path with an unquoted space fails the same way forever.
        let call = #"bash({"command":"rm /tmp/Screen Shot.png"})"#
        let err = "exit 1\nrm: /tmp/Screen: No such file or directory\n"
        _ = await probe.observe(call: call, result: err).warning
        let warning = await probe.observe(call: call, result: err).warning
        XCTAssertNotNil(warning, "repeating a command that fails identically is not recovery")
    }

    func testCompactionClearsTheComparison() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)

        // After compaction the model re-reads a file it no longer holds in context. That looks
        // identical to a fixed point and is the opposite of one.
        let read = #"read_file({"path":"spec.md"})"#
        _ = await probe.observe(call: read, result: "contents").warning
        await probe.reset()
        let warning = await probe.observe(call: read, result: "contents").warning
        XCTAssertNil(warning, "a reset must forget the history, not merely pause it")
    }

    func testItKeepsWarningForAsLongAsTheAgentIsStuck() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)

        // An earlier version spent a budget of two warnings and then fell silent. Measured over
        // nine executions, thirteen of the surviving repeats happened after that budget ran out
        // against one the probe had deliberately allowed — the cap switched the mechanism off
        // exactly where it was needed.
        let call = #"bash({"command":"true"})"#
        var issued = 0
        for _ in 0..<8 where await probe.observe(call: call, result: "exit 0").warning != nil {
            issued += 1
        }
        XCTAssertEqual(issued, 7, "every step at a fixed point is worth saying so about")
    }

    /// An alternating loop — `rm` that fails, `ls` that shows the same, twenty times over — has no
    /// two identical calls in a row. Consecutive-only detection never saw it; the whole run does.
    ///
    /// - Author: Claude
    func testAnAlternatingLoopIsCaught() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)
        let rm = #"bash({"command":"rm Screen Shot.png"})"#, ls = #"bash({"command":"ls"})"#
        _ = await probe.observe(call: rm, result: "exit 1\nrm: Screen: No such file")
        _ = await probe.observe(call: ls, result: "Screen Shot.png")
        let warning = await probe.observe(call: rm, result: "exit 1\nrm: Screen: No such file").warning
        XCTAssertNotNil(warning, "same call, same result, same world — two calls back")
    }

    /// The world moving between two runs of a check is progress.
    ///
    /// - Author: Claude
    func testARepeatAfterTheWorldMovedIsProgress() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)
        let check = #"bash({"command":"make test"})"#
        _ = await probe.observe(call: check, result: "FAIL")
        try write("fix", to: root, named: "a.c")
        _ = await probe.observe(call: #"write_file({"path":"a.c"})"#, result: "wrote a.c")
        let warning = await probe.observe(call: check, result: "FAIL").warning
        XCTAssertNil(warning, "a file changed between the two runs of the check")
    }

    /// The count a host escalates on, and the instruction the host gave it.
    ///
    /// - Author: Claude
    func testFiringsCountWarningsAndSurviveAReset() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)
        let call = #"bash({"command":"true"})"#
        _ = await probe.observe(call: call, result: "ok")
        let warning = await probe.observe(call: call, result: "ok", endInstruction: "call `finish` now").warning
        XCTAssertTrue(warning?.contains("call `finish` now") == true, warning ?? "")
        _ = await probe.observe(call: call, result: "ok")
        var firings = await probe.firings
        XCTAssertEqual(firings, 2)
        await probe.reset()
        firings = await probe.firings
        XCTAssertEqual(firings, 2, "compaction forgets the comparison, not that the agent was warned")
    }

    /// A repeat far back, with other calls in between, is still a repeat.
    ///
    /// - Author: Claude
    func testAnInterleavedRepeatOfTheSameStateIsFlagged() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)
        let search = #"web_search({"query":"youngest billionaire nationality"})"#
        let first = await probe.observe(call: search, result: "r1").warning
        XCTAssertNil(first)
        for other in 0..<8 {
            let quiet = await probe.observe(call: "web_search(\(other))", result: "r\(other)").warning
            XCTAssertNil(quiet)
        }
        let again = await probe.observe(call: search, result: "r1").warning
        XCTAssertTrue(again?.contains("already made this exact call") == true, again ?? "nil")
        let firings = await probe.firings
        XCTAssertEqual(firings, 1)
    }

    /// The workspace is compared by state: an edit that is reverted is back where it was, so
    /// re-reading the file then is a repeat. The same read after a real change is not.
    ///
    /// - Author: Claude
    func testTheWorkspaceIsComparedByState() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)
        let read = #"read_file({"path":"a.py"})"#
        try write("v1", to: root, named: "a.py")
        _ = await probe.observe(call: read, result: "v1")
        try write("v2", to: root, named: "a.py")
        let changed = await probe.observe(call: read, result: "v2").warning
        XCTAssertNil(changed, "a different state and a different result is progress")
        try write("v1", to: root, named: "a.py")
        let reverted = await probe.observe(call: read, result: "v1").warning
        XCTAssertNotNil(reverted, "back to an earlier state with the same answer is a repeat")
    }

    /// The same check failing the same way three times while files change in between — the edits
    /// are not affecting it. Twice is an ordinary retry.
    ///
    /// - Author: Claude
    func testTheSameResultDespiteEditsIsFlagged() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProgressProbe(root: root)
        let test = #"bash({"command":"python -m pytest tests/ -q"})"#
        for (attempt, expectFlag) in [(1, false), (2, false), (3, true)] {
            try write("attempt \(attempt)", to: root, named: "test_streak.py")
            let warning = await probe.observe(call: test, result: "1 failed").warning
            XCTAssertEqual(warning != nil, expectFlag, "attempt \(attempt): \(warning ?? "nil")")
            if expectFlag {
                XCTAssertTrue(warning?.contains("returned the same result 3 times") == true, warning ?? "")
            }
        }
    }
}
