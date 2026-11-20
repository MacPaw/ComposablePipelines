//
//  ModelBuildDiagnostic.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

//
//  ModelBuildDiagnostic.swift
//

import Foundation
import PipelineAST
#if canImport(Darwin)
import Darwin
#endif

/// A diagnostic produced at graph-build time when a ``Model`` step has invalid or
/// questionable arguments for its configured purpose.
///
/// Diagnostics are emitted to **stderr** as `[Model] <severity>: <issue>` lines.
/// Errors additionally call `assertionFailure` in `DEBUG` builds so they surface
/// immediately during development.
public struct ModelBuildDiagnostic: Sendable {
    public enum Severity: Sendable { case warning, error }
    public let severity: Severity
    public let issue: String
    public let recommendation: String?
}

// MARK: - Emitter

enum ModelBuildDiagnosticEmitter {

    static func warning(component: String, issue: String, recommendation: String? = nil) {
        emit([
            .init(
                severity: .warning,
                issue: issue,
                recommendation: recommendation
            ),
        ], component: component)
    }

    /// Validates `arguments` against `config` and emits any diagnostics to stderr.
    ///
    /// Enable opt-in missing-argument hints by setting `PIPELINE_VALIDATE_MODEL_ARGS=1`.
    static func validate(config: ModelConfig, arguments: ModelArguments) {
        var diagnostics: [ModelBuildDiagnostic] = []

        // MARK: Range checks — apply to all purposes

        if let tempArg = arguments[ModelArgument.temperature(0).key],
           case .temperature(let v) = tempArg, v < 0 || v > 2 {
            diagnostics.append(.init(
                severity: .error,
                issue: "temperature \(v) out of range [0, 2]",
                recommendation: "Use 0.0 (deterministic) … 2.0 (creative)."
            ))
        }
        if let tokArg = arguments[ModelArgument.maxTokens(0).key],
           case .maxTokens(let v) = tokArg, v <= 0 {
            diagnostics.append(.init(
                severity: .error,
                issue: "maxTokens must be > 0 (got \(v))",
                recommendation: nil
            ))
        }


        emit(diagnostics, component: "Model")
    }

    // MARK: - Private

    private static func emit(_ diagnostics: [ModelBuildDiagnostic], component: String) {
        for d in diagnostics {
            let tag: String
            switch d.severity {
            case .error:   tag = "error"
            case .warning: tag = "warning"
            }
            var line = "[\(component)] \(tag): \(d.issue)"
            if let rec = d.recommendation { line += " → \(rec)" }

            #if DEBUG
            if d.severity == .error { assertionFailure(line) }
            #endif

            stderr(line)
        }
    }

    private static func stderr(_ message: String) {
        #if canImport(Darwin)
        let colored = isatty(STDERR_FILENO) != 0
        #else
        let colored = false
        #endif
        let line = colored
            ? "\u{1B}[33m" + message + "\u{1B}[0m\n"
            : message + "\n"
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }
}
