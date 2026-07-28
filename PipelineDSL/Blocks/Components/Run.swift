//
//  Run.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Runs a Swift closure on the host and feeds its encoded result back into the graph —
/// the boundary for outside-world access (files, network, secrets, UI).
///
/// The graph records *that* a task runs (by `taskID`); the host decides *how*. Closure
/// captures never cross the wire — only the `taskID` does. When a graph is encoded and
/// executed remotely, give the task a stable string `id:` so the host's
/// `clientActionProvider` can dispatch the same identity across lowerings and launches
/// (see ``Foundation/UUID/init(stableTaskName:)``).
///
/// ```swift
/// Run($draft) { text in text.count }          // one binding in, types inferred
/// Run($draft, $tone) { draft, tone in … }     // two bindings in (lowers to `combine`)
/// Run { try await fetchUserLocale() }         // no input
/// Run(id: "word-count", $draft) { … }         // stable cross-wire identity
/// ```
///
/// Pure single-slot transforms read better as ``Binding/map(_:)``.
public struct Run<Input: Sendable & Codable & Hashable, Output: Sendable & Codable & Hashable>: LeafPipeline {

    @_spi(Internals) public let taskID: UUID
    public let input: () -> any Pipeline
    public let action: (@Sendable (Input) async throws -> Output)?
    @_spi(Internals) public let erasedAction: PipelineClientAction

    public init<InputPipeline: Pipeline>(
        taskID: UUID = UUID(),
        @PipelineBuilder input: @Sendable @escaping () -> InputPipeline,
        action: @escaping @Sendable (Input) async throws -> Output
    ) where InputPipeline.Output == Input {
        self.taskID = taskID
        self.input = { input().representedAsPipeline }
        self.action = action
        self.erasedAction = Self.erase(action)
    }

    public init(
        taskID: UUID = UUID(),
        input: Binding<Input>,
        action: @escaping @Sendable (Input) async throws -> Output
    ) {
        self.taskID = taskID
        self.input = { input.representedAsPipeline }
        self.action = action
        self.erasedAction = Self.erase(action)
    }

    public init(
        taskID: UUID = UUID(),
        action: @escaping @Sendable () async throws -> Output
    ) where Input == Never {
        self.taskID = taskID
        self.input = { EmptyPipeline().representedAsPipeline }
        self.action = nil
        self.erasedAction = { _ in
            let output = try await action()
            return try JSONEncoder().encode(output)
        }
    }

    private static func erase(
        _ action: @escaping @Sendable (Input) async throws -> Output
    ) -> PipelineClientAction {
        { data in
            let input = try JSONDecoder().decode(Input.self, from: data)
            let output = try await action(input)
            return try JSONEncoder().encode(output)
        }
    }

    fileprivate static func taskID(fromStableID id: String?) -> UUID {
        id.map(UUID.init(stableTaskName:)) ?? UUID()
    }
}

/// Previous name of ``Run``.
public typealias ClientTask = Run

// MARK: - Ergonomic spellings

extension Run {
    /// One binding in; `Input` comes from the binding, `Output` from the closure.
    public init(
        id: String? = nil,
        _ input: Binding<Input>,
        action: @escaping @Sendable (Input) async throws -> Output
    ) {
        self.init(taskID: Self.taskID(fromStableID: id), input: input, action: action)
    }

    /// No-input task with a stable cross-wire identity.
    public init(
        id: String,
        action: @escaping @Sendable () async throws -> Output
    ) where Input == Never {
        self.init(taskID: UUID(stableTaskName: id), action: action)
    }
}

// MARK: - Multi-binding inputs

extension Run {
    /// Two bindings in; the input lowers to ``PipelineGraphLeaf/combine(_:)`` and reaches the
    /// action as the decoded pair.
    public init<A, B>(
        id: String? = nil,
        _ first: Binding<A>,
        _ second: Binding<B>,
        action: @escaping @Sendable (A, B) async throws -> Output
    ) where Input == Combined2<A, B> {
        self.init(
            taskID: Self.taskID(fromStableID: id),
            input: {
                CombinedBindings<Input>(parts: [
                    first.representedAsPipeline,
                    second.representedAsPipeline,
                ])
            },
            action: { combined in try await action(combined.first, combined.second) }
        )
    }

    /// Three bindings in; the input lowers to ``PipelineGraphLeaf/combine(_:)`` and reaches the
    /// action as the decoded triple.
    public init<A, B, C>(
        id: String? = nil,
        _ first: Binding<A>,
        _ second: Binding<B>,
        _ third: Binding<C>,
        action: @escaping @Sendable (A, B, C) async throws -> Output
    ) where Input == Combined3<A, B, C> {
        self.init(
            taskID: Self.taskID(fromStableID: id),
            input: {
                CombinedBindings<Input>(parts: [
                    first.representedAsPipeline,
                    second.representedAsPipeline,
                    third.representedAsPipeline,
                ])
            },
            action: { combined in try await action(combined.first, combined.second, combined.third) }
        )
    }
}

/// Two independently-resolved values; the wire shape of ``PipelineGraphLeaf/combine(_:)``
/// (a two-element JSON array).
public struct Combined2<A: Sendable & Codable & Hashable, B: Sendable & Codable & Hashable>: Sendable, Codable, Hashable {
    public let first: A
    public let second: B

    public init(_ first: A, _ second: B) {
        self.first = first
        self.second = second
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        first = try container.decode(A.self)
        second = try container.decode(B.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(first)
        try container.encode(second)
    }
}

/// Three independently-resolved values; the wire shape of ``PipelineGraphLeaf/combine(_:)``
/// (a three-element JSON array).
public struct Combined3<
    A: Sendable & Codable & Hashable,
    B: Sendable & Codable & Hashable,
    C: Sendable & Codable & Hashable
>: Sendable, Codable, Hashable {
    public let first: A
    public let second: B
    public let third: C

    public init(_ first: A, _ second: B, _ third: C) {
        self.first = first
        self.second = second
        self.third = third
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        first = try container.decode(A.self)
        second = try container.decode(B.self)
        third = try container.decode(C.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(first)
        try container.encode(second)
        try container.encode(third)
    }
}

/// Lowers a fixed set of input pipelines to a single ``PipelineGraphLeaf/combine(_:)`` leaf.
private struct CombinedBindings<Output: Sendable & Codable & Hashable>: LeafPipeline {
    let parts: [any Pipeline]

    var pipelineGraph: PipelineGraph {
        .leaf(.combine(parts.map(\.pipelineGraph)))
    }
}

// MARK: - Direct execution

extension Run {
    public func execute(_ input: Input) async throws -> Output {
        guard let action else {
            fatalError("No typed action is available for no-input Run")
        }
        return try await action(input)
    }
}

extension Run where Input == Never {
    public func execute() async throws -> Output {
        let data = try await erasedAction(Data())
        return try JSONDecoder().decode(Output.self, from: data)
    }
}

// MARK: - Graph emission

extension Run {
    public var pipelineGraph: PipelineGraph {
        GraphEmissionContext.current?.recordClientAction(taskID: taskID, action: erasedAction)
        return .leaf(
            .clientAction(taskID: taskID, input: input().pipelineGraph)
        )
    }
}
