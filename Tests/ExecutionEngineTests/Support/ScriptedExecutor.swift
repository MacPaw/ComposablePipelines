//
//  ScriptedExecutor.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST
@testable import ExecutionEngine

/// A scripted ``Executor`` for tests: the test supplies each model output, so intermediate
/// `@State` values are meaningful. (``MockExecutor`` reports `noBackend` for every model
/// call, which the walker turns into an empty-string fallback — fine for structural traces,
/// useless for asserting produced values.) Guardrails pass by default.
///
/// `ClientTask` closures are *not* routed here — they are captured at lowering and run as
/// written, so only `Model`/`Guardrail` steps need scripting.
struct ScriptedExecutor: Executor {

    /// One resolved model invocation. Inputs are decoded best-effort to `String` for routing.
    struct ModelCall: Sendable {
        let instructions: String
        let input: String
        let outputTypeName: String
        let requirements: ModelSelectionRequirements?
    }

    private let respond: @Sendable (ModelCall) throws -> ExecutionValue
    private let guardrailPasses: Bool

    init(
        guardrailPasses: Bool = true,
        respond: @escaping @Sendable (ModelCall) throws -> ExecutionValue
    ) {
        self.respond = respond
        self.guardrailPasses = guardrailPasses
    }

    func runModel(
        instructions: ExecutionValue,
        tools: ExecutionValue,
        input: ExecutionValue,
        outputTypeName: String,
        requirements: ModelSelectionRequirements?
    ) async throws -> ExecutionValue {
        try respond(
            ModelCall(
                instructions: Self.decodeString(instructions),
                input: Self.decodeString(input),
                outputTypeName: outputTypeName,
                requirements: requirements
            )
        )
    }

    func runGuardrail(rules: [GuardrailRule]) async throws -> ExecutionValue {
        try JSONEncoder().encode(guardrailPasses)
    }

    /// JSON-decode bytes to `String`; fall back to the raw UTF-8 view so non-`String`
    /// inputs (e.g. `[ContextItem]`) still yield something routable.
    static func decodeString(_ value: ExecutionValue) -> String {
        if let string = try? JSONDecoder().decode(String.self, from: value) { return string }
        return String(decoding: value, as: UTF8.self)
    }
}

// MARK: - Output encoding

extension ScriptedExecutor {

    /// Encode a plain `String` model output.
    static func string(_ value: String) -> ExecutionValue {
        (try? JSONEncoder().encode(value)) ?? Data.emptyJSON
    }

    /// Encode a `ModelTurn` output (final reply and/or tool calls).
    static func turn(reply: String? = nil, toolCalls: [ToolCall] = []) -> ExecutionValue {
        let turn = ModelTurn(reply: reply, toolCalls: toolCalls.isEmpty ? nil : toolCalls)
        return (try? JSONEncoder().encode(turn)) ?? Data.emptyJSON
    }
}

// MARK: - Sequence convenience

extension ScriptedExecutor {

    /// Returns the given `String` outputs in call order, repeating the last once exhausted.
    static func sequence(_ outputs: [String]) -> ScriptedExecutor {
        let cursor = Cursor(outputs.map(string))
        return ScriptedExecutor { _ in cursor.next() }
    }

    /// Thread-safe call counter backing ``sequence(_:)`` (model steps can run concurrently).
    private final class Cursor: @unchecked Sendable {
        private let lock = NSLock()
        private let values: [ExecutionValue]
        private var index = 0

        init(_ values: [ExecutionValue]) {
            precondition(!values.isEmpty, "ScriptedExecutor.sequence needs at least one output")
            self.values = values
        }

        func next() -> ExecutionValue {
            lock.lock(); defer { lock.unlock() }
            let value = values[Swift.min(index, values.count - 1)]
            index += 1
            return value
        }
    }
}
