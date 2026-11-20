//
//  SubagentIdentity.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Which subagent is running, for code a delegate child reaches but passes no arguments to.
///
/// A child's tools are the parent's — the inheritance mask forwards the same provider — so a tool call
/// carries no sender. Anything wanting per-subagent behaviour (its own shell, a prompt naming who is
/// asking) has nothing else to key on.
///
/// `nil` means no subagent is running: the parent run itself, and every pipeline that never delegates.
public struct SubagentIdentity: Codable, Hashable, Sendable {

    /// Bound by the walker around each child, because the code that needs the answer sits behind
    /// interfaces that take no such argument.
    ///
    /// The *task-local* does not cross a process boundary: a host running client actions out of
    /// process must carry the value in its own transport and re-bind it on arrival.
    ///
    /// The **type** does cross one — `ElixRuntime` carries it on `ExecuteClientTask` — so by `CLAUDE.md`
    /// it is an IPC type: changing its stored properties, their order or their `Codable` behaviour is
    /// a wire change, and it lives in the mirrored package, so it needs the mirror process too.
    @TaskLocal public static var current: SubagentIdentity?

    /// Position in the delegate tree, outermost first, and **zero-based** — the walker binds each
    /// child's own index from `tasks.indices`, and `DelegateRunID` spells the first child `root.0`.
    /// So `[1, 2]` is the child at index 2 of the child at index 1: the third child of the second.
    /// Stable for the child's lifetime and unique among siblings.
    public let path: [Int]

    /// A short summary of the task this subagent was seeded with, for surfaces that ask a person to
    /// decide something on its behalf.
    public let label: String?

    public init(path: [Int], label: String? = nil) {
        self.path = path
        self.label = label
    }

    /// `"1.2"` — for where a key has to be a single string.
    public var key: String {
        path.map(String.init).joined(separator: ".")
    }

    /// What to show a person: the label when there is one, the path otherwise.
    public var displayName: String {
        guard let label, !label.isEmpty else { return "subagent \(key)" }
        return "subagent \(key) · \(label)"
    }
}
