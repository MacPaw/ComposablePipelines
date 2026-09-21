//
//  Theme.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A truecolor ANSI dark theme (Catppuccin Mocha-ish). Degrades to plain text when output is not a
/// TTY or `NO_COLOR` is set, so piped/redirected output stays clean.
struct Theme {
    struct RGB { let r, g, b: Int }

    // Palette
    let text   = RGB(r: 205, g: 214, b: 244)  // soft white
    let subtle = RGB(r: 147, g: 153, b: 178)  // muted
    let faint  = RGB(r: 88,  g: 91,  b: 112)  // dim gray
    let accent = RGB(r: 137, g: 180, b: 250)  // blue
    let mauve  = RGB(r: 203, g: 166, b: 247)  // violet (thinking)
    let green  = RGB(r: 166, g: 227, b: 161)  // success
    let peach  = RGB(r: 250, g: 179, b: 135)  // tool calls

    let enabled: Bool
    let width: Int

    let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init() {
        let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        let isTTY = isatty(fileno(stdout)) != 0
        enabled = isTTY && !noColor
        if let cols = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(cols), n > 20 {
            width = min(n, 100)
        } else {
            width = 90
        }
    }

    // MARK: - SGR

    var reset: String { enabled ? "\u{1B}[0m" : "" }
    var bold: String { enabled ? "\u{1B}[1m" : "" }
    var dim: String { enabled ? "\u{1B}[2m" : "" }
    var italic: String { enabled ? "\u{1B}[3m" : "" }
    var clearLine: String { enabled ? "\u{1B}[2K" : "" }
    var hideCursor: String { enabled ? "\u{1B}[?25l" : "" }
    var showCursor: String { enabled ? "\u{1B}[?25h" : "" }

    func fg(_ c: RGB) -> String { enabled ? "\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m" : "" }

    /// Wrap `s` in a foreground color (and optional styles), resetting after.
    func paint(_ s: String, _ c: RGB, _ styles: String = "") -> String {
        guard enabled else { return s }
        return styles + fg(c) + s + reset
    }
}
