//
//  ProgressProbe.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Detects that an agent has stopped making progress, rather than that it has repeated itself.
///
/// Repeating a tool call is ordinary and often correct: re-running a build after an edit,
/// re-listing a directory a background job is filling, re-checking a status that is expected
/// to change. A rule that flags repetition as such punishes all of those. What is never
/// productive is being at a **fixed point** — applying an action that maps the world back to
/// a state it was already in, and getting the answer it already got.
///
/// So the question asked here is not "same call?" but "same call, same answer, same world?".
/// A step counts as progress if *anything* moved:
///
/// - the **workspace** is in a state it has not been in before — the agent acted on the world, or
/// - the **result** is new — the agent learned something it did not know.
///
/// Each call is judged against the **whole run**, by two rules:
///
/// 1. **Repeated state** — the same call returned the same result with the workspace in the same
///    state at any earlier point. Nothing about it can be new. The workspace is compared by
///    state, so an edit that is reverted is back where it was.
/// 2. **Same result despite edits** — the same call has returned the same result three times
///    while the workspace changed in between: the agent's edits are not affecting what it is
///    checking (a test re-run after each attempt, failing the same way).
///
/// An earlier version looked only for *consecutive* repeats within a window of recent calls.
/// Measured loops interleave (read, edit, read, revert) and cycle through more than six calls, and
/// both reset a streak: replayed over 565 recorded runs, the whole-run rules flag 118 of the 151
/// that exhausted the turn budget, the windowed rule 57.
///
/// The workspace is the right notion of "the world" here because it is what the objective
/// verifier judges. State the agent changes outside the working directory is invisible to this probe — and
/// equally invisible to grading, so the two agree.
///
/// The probe warns every time a rule matches, for as long as one does. An earlier version spent a
/// budget of two warnings and then fell silent; measurement showed the agent complied with each
/// warning and stalled somewhere else, so the budget switched the probe off where it was working.
///
/// - Author: Claude
actor ProgressProbe {

    /// One observed step: what was called, what came back, and what the world looked like after.
    private struct Step: Equatable {
        let call: String
        let result: String
        let workspace: String
    }

    private let root: URL

    /// Every step of the run so far — call and result as digests, so a run of large file reads does
    /// not hold every file's contents.
    private var history: [Step] = []
    /// Warnings issued this run. A host escalates on this: an agent that steps off one fixed point
    /// and onto another has been warned twice.
    private(set) var firings = 0

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// What the probe concluded about one step.
    ///
    /// `note` is always present, and says *why* — including why it stayed quiet. A probe that
    /// only reports when it fires cannot be told apart from one that is broken.
    struct Observation: Sendable {
        /// Guidance to put in front of the model, or `nil` when there is nothing to say.
        let warning: String?
        /// One line of reasoning, for the transcript.
        let note: String
    }

    /// Record a completed tool call and judge whether the agent is getting anywhere.
    ///
    /// Call this *after* the tool has run, so the workspace digest reflects its effect.
    ///
    /// - Parameter endInstruction: What the warning tells the agent to do when it is done — the
    ///   host knows whether it has a way to end the run, the probe does not.
    func observe(call: String, result: String,
                        endInstruction: String = "reply with your final answer now") -> Observation {
        let step = Step(call: Self.sha(call), result: Self.sha(result), workspace: digest())
        defer { history.append(step) }
        let tool = Self.toolName(of: call)
        if history.contains(step) {
            firings += 1
            return Observation(
                warning: "(You already made this exact call to \(tool) with the working directory "
                    + "in this same state, and it returned the same result — it cannot tell you "
                    + "anything new. Do NOT repeat it. Either do something different, or, if the "
                    + "task is already done, \(endInstruction).)",
                note: "REPEATED STATE on \(tool) — warning \(firings) issued")
        }
        let sameResult = history.filter { $0.call == step.call && $0.result == step.result }.count
        if sameResult >= 2 {
            firings += 1
            return Observation(
                warning: "(This call to \(tool) has now returned the same result \(sameResult + 1) "
                    + "times, although you changed files in between — your changes are not "
                    + "affecting it. Rethink the approach instead of editing and re-running again, "
                    + "or, if the task is already done, \(endInstruction).)",
                note: "SAME RESULT on \(tool) across \(sameResult + 1) calls despite edits — "
                    + "warning \(firings) issued")
        }
        return Observation(warning: nil, note: "progress: new call, result or workspace state")
    }

    /// Forget the previous steps.
    ///
    /// Called when the transcript is compacted: the model legitimately re-reads a file to bring
    /// it back into a context it no longer holds, which looks like a fixed point but is not one.
    /// `firings` is kept: the agent was warned whether or not the history still shows it.
    func reset() {
        history = []
    }

    /// A cheap fingerprint of the working directory: every file's path and a SHA-256 of its
    /// contents (its size, for a file too large to hash), in a stable order.
    ///
    /// Contents and not modification time, because the question is "did anything move" and a
    /// rewrite with identical bytes does not move anything — while its timestamp does. Keyed on
    /// mtime, this digest reported a no-op rewrite as progress and the probe stayed silent
    /// through exactly the loop it exists to catch: on one measured case, 18 of 30 calls were
    /// `write_file`, in streaks of up to five identical writes each returning
    /// `wrote solution.py (27 bytes)`, and only 10 of the 30 calls were distinct.
    ///
    /// The cost is reading the tree once per tool call. These workspaces hold a handful of small
    /// files, and a file too large to hash cheaply falls back to its size — a loop that rewrites
    /// a multi-megabyte file identically is not a failure mode worth the read.
    ///
    /// - Author: Claude
    private func digest() -> String {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return "" }

        var lines: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            let path = url.path.hasPrefix(root.path)
                ? String(url.path.dropFirst(root.path.count)) : url.path
            let mark: String
            if size <= Self.hashableFileBytes, let data = try? Data(contentsOf: url) {
                mark = Self.fingerprint(data)
            } else {
                mark = "size:\(size)"
            }
            lines.append("\(path)\t\(mark)")
        }
        lines.sort()
        let joined = lines.joined(separator: "\n")
        return Self.fingerprint(Data(joined.utf8))
    }

    /// Above this, a file is fingerprinted by size alone rather than read on every tool call.
    ///
    /// - Author: Claude
    private static let hashableFileBytes = 2 * 1024 * 1024

    /// A fingerprint of a string, hex. See ``fingerprint(_:)``.
    ///
    /// - Author: Claude
    private static func sha(_ text: String) -> String {
        fingerprint(Data(text.utf8))
    }

    /// A 128-bit FNV-1a fingerprint of `data` (two 64-bit lanes with different offset bases), hex.
    ///
    /// The fingerprints only tell, within one run, whether a workspace or a result is one already seen; nothing
    /// relies on them resisting a crafted collision. FNV is portable (no CryptoKit, which Linux lacks) and fast.
    static func fingerprint(_ data: Data) -> String {
        let prime: UInt64 = 0x0000_0100_0000_01B3
        var low: UInt64 = 0xCBF2_9CE4_8422_2325
        var high: UInt64 = 0x6C62_272E_07BB_0142
        for byte in data {
            low = (low ^ UInt64(byte)) &* prime
            high = (high ^ UInt64(byte ^ 0x5A)) &* prime
        }
        return String(format: "%016llx%016llx", high, low)
    }

    /// The tool name out of a `name(args)` signature.
    private static func toolName(of signature: String) -> String {
        let name = signature.prefix(while: { $0 != "(" })
        return name.isEmpty ? "that tool" : String(name)
    }
}
