//
//  SelfHealingExtractionPipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineDSL

/// Self-correcting extraction: ask a model for JSON, validate it with a plain-Swift check, and
/// retry — feeding the previous error back into the prompt — until it is valid or attempts run out.
///
/// Demonstrates:
/// - `While` as a reactive retry loop driven by ordinary `@State`. Each committed write bumps the
///   epoch, the pipeline re-lowers, and the condition is re-evaluated; the loop stops when `valid`
///   flips or `attempts` reaches the cap.
/// - A `Model` step *inside a loop body*: it re-runs every iteration (its output is what the loop
///   is trying to get right), and `lastError` — read here at lowering — is folded into each retry's
///   prompt.
/// - `$slot.map { … }` for plain-Swift validation on the host, threading state through the
///   binding's value rather than reading `@State` inside the closure (which is disallowed).
struct SelfHealingExtractionPipeline: Pipeline {
    typealias Output = String

    let text: String
    let maxAttempts: Int

    @State var candidate: String = ""
    @State var valid: Bool = false
    @State var lastError: String = ""
    @State var attempts: Int = 0

    init(text: String, maxAttempts: Int = 3) {
        self.text = text
        self.maxAttempts = maxAttempts
    }

    var body: some Pipeline {
        While(!valid && attempts < maxAttempts) {
            // Prompt folds bare `lastError` (@State) into each retry → closure form captures it.
            $candidate.set {
                Model<String>("""
                    Extract the person's name and age as a JSON object {"name":…,"age":…}. \
                    \(lastError.isEmpty ? "" : "Your previous attempt was rejected: \(lastError)")
                    """)
                    .message(text)
            }
            $candidate.map { json in Self.isValidPersonJSON(json) }
                .assign(to: $valid)
            $candidate.map { json in
                Self.isValidPersonJSON(json) ? "" : "expected a JSON object with name and age"
            }
            .assign(to: $lastError)
            $attempts.map { $0 + 1 }.assign(to: $attempts)
        }
        $candidate
    }

    /// Accepts only a JSON object carrying both `name` and `age`.
    static func isValidPersonJSON(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["name"] != nil && object["age"] != nil
    }
}
