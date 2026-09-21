//
//  InstructionsBuilder.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

/// Result builder for multi-line prompts: each expression contributes one line, joined with
/// newlines. Supports `if`/`else`, `if` without `else`, and `for` loops.
///
/// ```swift
/// Model<String> {
///     "Write a research brief from these notes."
///     "Cite every fact you use."
///     if audience == .expert { "Assume deep domain knowledge." }
/// }
/// ```
@resultBuilder
public enum InstructionsBuilder {
    public static func buildBlock(_ components: String...) -> String {
        components.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func buildExpression(_ expression: String) -> String {
        expression
    }

    public static func buildOptional(_ component: String?) -> String {
        component ?? ""
    }

    public static func buildEither(first component: String) -> String {
        component
    }

    public static func buildEither(second component: String) -> String {
        component
    }

    public static func buildArray(_ components: [String]) -> String {
        components.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func buildLimitedAvailability(_ component: String) -> String {
        component
    }
}
