//
//  Group.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
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

public extension Group {
    /// Turns this group into a barrier: everything after it waits for it to finish,
    /// regardless of slot dependencies. Reads better than `Group(gate: true)`:
    ///
    /// ```swift
    /// Group { … }.gated()
    /// ```
    func gated() -> Group {
        Group(sequential: sequential, gate: true) { content }
    }
}

/// A group whose steps may run concurrently — the readable spelling of
/// `Group(sequential: false)`. The compiler is free to parallelize independent steps inside.
///
/// ```swift
/// Concurrent {
///     Model<String>("Summarize").input { $a }.assign(to: $summaryA)
///     Model<String>("Summarize").input { $b }.assign(to: $summaryB)
/// }
/// ```
public struct Concurrent<Content: Pipeline>: Pipeline, PipelineStructuralNode {
    public typealias Output = Content.Output
    public typealias Body = Never

    public let gate: Bool
    public let content: Content

    public init(gate: Bool = false, @PipelineBuilder _ content: () -> Content) {
        self.gate = gate
        self.content = content()
    }

    public var body: Never {
        fatalError("Concurrent is a structural node; use content property")
    }
}

extension Concurrent: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph {
        .group(sequential: false, gate: gate, content.pipelineGraph)
    }
}

/// A barrier: everything after this block waits for it to complete, regardless of slot
/// dependencies. The readable spelling of `Group(gate: true)`.
///
/// ```swift
/// Barrier {
///     GateGuardrail(.politics, .pii) { $message.get() }
/// }
/// ```
public struct Barrier<Content: Pipeline>: Pipeline, PipelineStructuralNode {
    public typealias Output = Content.Output
    public typealias Body = Never

    public let sequential: Bool
    public let content: Content

    public init(sequential: Bool = true, @PipelineBuilder _ content: () -> Content) {
        self.sequential = sequential
        self.content = content()
    }

    public var body: Never {
        fatalError("Barrier is a structural node; use content property")
    }
}

extension Barrier: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph {
        .group(sequential: sequential, gate: true, content.pipelineGraph)
    }
}
