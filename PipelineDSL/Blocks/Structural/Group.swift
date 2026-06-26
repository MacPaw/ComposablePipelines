//
//  Group.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Explicit grouping block.
/// - `sequential` (default `true`): the compiler treats the group as a single
///   atomic unit — no internal parallelization.
/// - `gate` (default `false`): everything after this group must wait for it to
///   complete before executing, regardless of slot dependencies.
///
/// ```swift
/// Group(gate: true) {
///     Guardrail(rules: [.politics, .pii])
/// }
///
/// Group {
///     $context.set { Model<String>().systemPrompt("Summarize").message($history) }
///     Model<String>().systemPrompt("Reply").message($context)
/// }
/// ```
public struct Group<Content: Pipeline>: Pipeline, PipelineStructuralNode {
    public typealias Output = Content.Output
    public typealias Body = Never

    public let sequential: Bool
    public let gate: Bool
    public let content: Content

    public init(
        sequential: Bool = true,
        gate: Bool = false,
        @PipelineBuilder _ content: () -> Content
    ) {
        self.sequential = sequential
        self.gate = gate
        self.content = content()
    }

    public var body: Never {
        fatalError("Group is a structural node; use content property")
    }
}

extension Group: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph {
        .group(sequential: sequential, gate: gate, content.pipelineGraph)
    }
}
