//
//  Guardrail.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

private extension GuardrailRule {
    var classificationDescription: String {
        switch self {
        case .illegal:
            return "Requests to facilitate, plan, or carry out illegal activities."
        case .harmful:
            return "Content that promotes self-harm, violence, harassment, or other harmful behaviour."
        case .sexual:
            return "Explicit sexual content or requests of a sexual nature."
        case .malicious:
            return "Malicious intent: social engineering, deception, scams, or manipulation."
        case .geopolitics, .politics:
            return "Political persuasion, campaigning, or requests to manipulate political opinions."
        case .pii:
            return "Personally identifiable information: names, addresses, credentials, or other private data."
        }
    }
}

/// Typed guardrail classification implemented through the ordinary model workflow.
public struct GuardrailClassification<Input: Pipeline>: LeafPipeline
where Input.Output == String {
    public typealias Output = Bool

    public let input: Input
    public let rules: [GuardrailRule]

    public init(
        rules: [GuardrailRule],
        @PipelineBuilder input: () -> Input
    ) {
        if rules.isEmpty {
            Self.emitEmptyRulesWarning()
        }
        self.input = input()
        self.rules = rules
    }

    public var pipelineGraph: PipelineGraph {
        guard !rules.isEmpty else {
            return Just(value: true).pipelineGraph
        }
        return Model<Bool>(traits: .guardrailClassification)
            .parameter(.guardrailRules, rules)
            .input { input }
            .pipelineGraph
    }

    private static func emitEmptyRulesWarning() {
        ModelBuildDiagnosticEmitter.warning(
            component: "Guardrail",
            issue: "classification created with an empty rule set",
            recommendation: "The classifier will be skipped and the result will be true."
        )
    }
}

public extension GuardrailClassification {
    /// Variadic-rules spelling: `GuardrailClassification(.politics, .pii) { input }`.
    init(
        _ rules: GuardrailRule...,
        @PipelineBuilder input: () -> Input
    ) {
        self.init(rules: rules, input: input)
    }
}

public extension GuardrailClassification where Input == Just<String> {
    init(_ input: String, rules: [GuardrailRule]) {
        self.init(rules: rules) {
            Just(value: input)
        }
    }
}

/// Classifies input and executes exactly one of the supplied pipelines.
///
/// This is syntax sugar over ``GuardrailClassification``, execution state, and
/// native PipelineDSL `if`/`else`. The compiler and engine receive no special
/// guardrail operation.
public struct Guardrail<Input: Pipeline, Allowed: Pipeline, Blocked: Pipeline>: Pipeline
where Input.Output == String, Allowed.Output == Blocked.Output {
    public typealias Output = Allowed.Output

    public let input: Input
    public let rules: [GuardrailRule]
    public let allowed: Allowed
    public let blocked: Blocked

    @State private var isAllowed: Bool

    public init(
        rules: [GuardrailRule],
        @PipelineBuilder input: () -> Input,
        @PipelineBuilder allowed: () -> Allowed,
        @PipelineBuilder blocked: () -> Blocked
    ) {
        if rules.isEmpty {
            Self.emitEmptyRulesWarning()
        }
        self.input = input()
        self.rules = rules
        self.allowed = allowed()
        self.blocked = blocked()
        self._isAllowed = State(
            wrappedValue: false,
            id: GraphEmissionContext.current?.nextStableID() ?? UUID(),
            "guardrailAllowed"
        )
    }

    public var body: some Pipeline {
        if rules.isEmpty {
            allowed
        } else {
            $isAllowed.set {
                GuardrailClassification(rules: rules) { input }
            }
            if isAllowed {
                allowed
            } else {
                blocked
            }
        }
    }

    private static func emitEmptyRulesWarning() {
        ModelBuildDiagnosticEmitter.warning(
            component: "Guardrail",
            issue: "guardrail created with an empty rule set",
            recommendation: "The classifier and blocked branch will be skipped."
        )
    }
}

public extension Guardrail where Input == Just<String> {
    init(
        _ input: String,
        rules: [GuardrailRule],
        @PipelineBuilder allowed: () -> Allowed,
        @PipelineBuilder blocked: () -> Blocked
    ) {
        self.init(
            rules: rules,
            input: { Just(value: input) },
            allowed: allowed,
            blocked: blocked
        )
    }
}

// MARK: - Bare gating guardrail

/// Content-safety gate with no branches — classifies `input` against `rules` and only
/// proceeds when it passes. Sugar over ``GuardrailClassification`` plus an early `return`
/// through ``State``; the compiler and engine receive no special guardrail operation.
///
/// ```swift
/// GateGuardrail(.politics, .pii) { $message.get() }
/// ```
public struct GateGuardrail<Input: Pipeline>: Pipeline where Input.Output == String {
    public typealias Output = Bool

    public let input: Input
    public let rules: [GuardrailRule]

    public init(
        _ rules: GuardrailRule...,
        @PipelineBuilder input: () -> Input
    ) {
        self.rules = rules
        self.input = input()
    }

    public var body: some Pipeline {
        GuardrailClassification(rules: rules) { input }
    }
}
