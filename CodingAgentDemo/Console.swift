//
//  Console.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines

/// Serializes all stdout rendering behind a lock so the animated spinner and event-driven lines
/// never interleave mid-write. Permanent lines are printed above a transient, animated status line.
final class Console: @unchecked Sendable {
    private let lock = Lock()
    private let theme: Theme
    private var status: String?
    private var frame = 0
    private var contextWindow: Int?
    private var contextGauge: String?

    init(theme: Theme) { self.theme = theme }

    // MARK: - Context usage

    /// The model's context window, used to render the live usage gauge.
    func setContextWindow(_ tokens: Int) {
        lock.lock(); contextWindow = tokens; lock.unlock()
    }

    /// Report the context (prompt) tokens the server consumed on the latest turn; shown live in the
    /// status line as `ctx used/window`.
    func reportContextTokens(_ used: Int) {
        lock.lock(); defer { lock.unlock() }
        if let window = contextWindow {
            contextGauge = "ctx \(Self.humanTokens(used))/\(Self.humanTokens(window))"
        } else {
            contextGauge = "ctx \(Self.humanTokens(used))"
        }
        if theme.enabled, status != nil { renderStatusLocked() }
    }

    private static func humanTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

    // MARK: - Transient status (spinner)

    /// Set or clear the animated status line (e.g. "thinking…"). `nil` clears it.
    func setStatus(_ text: String?) {
        lock.lock(); defer { lock.unlock() }
        status = text
        guard theme.enabled else { return }
        if text == nil {
            out("\r" + theme.clearLine + theme.showCursor)
        } else {
            out(theme.hideCursor)
            renderStatusLocked()
        }
    }

    /// Advance the spinner one frame (call on a timer).
    func tick() {
        lock.lock(); defer { lock.unlock() }
        guard theme.enabled, status != nil else { return }
        frame &+= 1
        renderStatusLocked()
    }

    private func renderStatusLocked() {
        guard let text = status else { return }
        let f = theme.spinnerFrames[frame % theme.spinnerFrames.count]
        var line = theme.paint("\(f) \(text)", theme.mauve, theme.dim)
        if let gauge = contextGauge {
            line += theme.paint("  ·  \(gauge)", theme.faint)
        }
        out("\r" + theme.clearLine + line)
    }

    // MARK: - Permanent lines

    /// Print a finished line, clearing the spinner first and redrawing it after.
    func line(_ s: String = "") {
        lock.lock(); defer { lock.unlock() }
        if theme.enabled, status != nil { out("\r" + theme.clearLine) }
        out(s + "\n")
        if theme.enabled, status != nil { renderStatusLocked() }
    }

    // MARK: - Semantic rendering

    func banner(agent: String, model: String, dir: String, limits: String) {
        let a = theme.accent
        line()
        line(theme.paint("  ◆ cp-agent", a, theme.bold) + theme.paint("  ·  \(agent)", theme.subtle))
        line(theme.paint("  model ", theme.faint) + theme.paint(model, theme.subtle))
        line(theme.paint("  limit ", theme.faint) + theme.paint(limits, theme.subtle))
        line(theme.paint("  dir   ", theme.faint) + theme.paint(dir, theme.subtle))
        line(theme.paint("  ────────────────────────────────────────────", theme.faint))
        line(theme.paint("  type a task · ", theme.faint) + theme.paint("exit", theme.subtle) + theme.paint(" to quit", theme.faint))
        line()
    }

    /// The user's prompt symbol (printed before readLine; the typed text echoes after it).
    func promptPrefix() -> String { theme.paint("❯ ", theme.accent, theme.bold) }

    func userEcho(_ message: String) {
        // Non-TTY: echo what was received so transcripts read sensibly.
        if !theme.enabled { line("> " + message) }
    }

    func thinking() { setStatus("thinking…") }

    /// The model's interim narration — dim italic, distinct from tool calls and the final answer.
    func reasoning(_ text: String) {
        for row in wrap(text, width: theme.width - 4) {
            line("  " + theme.paint(row, theme.mauve, theme.dim + theme.italic))
        }
    }

    func toolCall(name: String, arguments: String) {
        let args = compact(arguments, limit: theme.width - 8)
        line("  " + theme.paint("⚙ \(name)", theme.peach) + theme.paint(" \(args)", theme.faint))
        setStatus("working…")
    }

    func answer(_ text: String) {
        setStatus(nil)
        line()
        let bar = theme.paint("▌", theme.accent)
        for raw in wrap(text, width: theme.width - 4) {
            line(" \(bar) " + theme.paint(raw, theme.text))
        }
        line()
    }

    func note(_ text: String) {
        setStatus(nil)
        line(theme.paint("  ! \(text)", theme.peach))
    }

    func goodbye() {
        setStatus(nil)
        line(theme.paint("  ✦ bye", theme.subtle))
    }

    // MARK: - Helpers

    private func compact(_ s: String, limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(Swift.max(0, limit - 1))) + "…"
    }

    /// Word-wrap to `width`, preserving existing newlines (so paragraphs/lists survive).
    private func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                if current.isEmpty {
                    current = String(word)
                } else if current.count + 1 + word.count <= width {
                    current += " " + word
                } else {
                    lines.append(current)
                    current = String(word)
                }
            }
            lines.append(current)
        }
        return lines
    }
}
