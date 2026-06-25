//
//  Timing.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Dispatch

/// Monotonic elapsed-time measurement, in nanoseconds. Open replacement for `Stopwatch`.
package struct ElapsedTimer: Sendable {

    private let start = DispatchTime.now()

    package init() {}

    /// Nanoseconds elapsed since creation (`dispatch_time_t`-compatible `UInt64`).
    package func nanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
    }
}

package extension UInt64 {
    /// Human-readable formatting of a nanosecond duration (e.g. "340µs", "1.2ms", "3.4s").
    var prettyDuration: String {
        let ns = self
        if ns < 1_000 { return "\(ns)ns" }
        let µs = Double(ns) / 1_000
        if µs < 1_000 { return µs < 10 ? String(format: "%.1fµs", µs) : String(format: "%.0fµs", µs) }
        let ms = Double(ns) / 1_000_000
        if ms < 1_000 {
            if ms >= 100 { return String(format: "%.0fms", ms) }
            if ms >= 10 { return String(format: "%.1fms", ms) }
            return String(format: "%.2fms", ms)
        }
        let s = Double(ns) / 1_000_000_000
        return s < 10 ? String(format: "%.2fs", s) : String(format: "%.1fs", s)
    }
}
