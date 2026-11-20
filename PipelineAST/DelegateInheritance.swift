//
//  DelegateInheritance.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

/// Which of a parent run's capabilities a `.delegate` subagent inherits.
///
/// A delegate child's *state* is always isolated — it gets a fresh `ExecutionContext` and sees only the
/// task seeded into its input slot, never the parent's or its siblings' slots. This mask governs the
/// orthogonal question of which *shared* capabilities that isolated child may reach.
///
/// The default is ``isolated`` (`[]`): a subagent inherits nothing, so the parent must **opt in** to
/// exactly the context each child needs. This keeps the delegate's "tiny context per subagent" premise
/// the default rather than something an author has to remember to enforce.
///
/// - Author: Claude
public struct DelegateInheritance: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The client-action provider — required for a child to run any `ClientTask` step or client tool.
    public static let tools = DelegateInheritance(rawValue: 1 << 0)
    /// The parent's context-item providers — a child's `.contextItems` steps resolve through them.
    public static let context = DelegateInheritance(rawValue: 1 << 1)
    /// The parent's memory store — a child's `Memory.recall` / memory-store steps reach it.
    public static let memory = DelegateInheritance(rawValue: 1 << 2)

    /// Inherit nothing — the fully isolated default: a child sees only its seeded task.
    public static let isolated: DelegateInheritance = []
    /// Inherit every capability (the pre-mask behavior: tools, context, and memory).
    public static let all: DelegateInheritance = [.tools, .context, .memory]
}
