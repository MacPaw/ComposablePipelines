//
//  DelegateBrief.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import ComposablePipelines
import Foundation

/// What a parent publishes as *selectable* when it asks a model to split its work.
///
/// The menu is the upper bound on every grant: a model picks names out of it, and
/// ``DelegationTool/briefs(from:menu:)`` resolves those names against it. Content never travels the
/// other way — the model sees tool names and context **labels**, and the parent supplies the actual
/// descriptors and items. That asymmetry is what makes it safe to let model output decide who gets
/// what: the worst a bad completion can do is name something that is not on the menu, which is dropped.
///
/// - Author: Claude
public struct DelegationMenu: Sendable {
    /// The tools a subagent may be granted. A brief's `toolNames` are always a subset of these names.
    public var tools: [ToolDescriptor]
    /// Pre-fetched context, keyed by the short label the model refers to it by. Values are *data* the
    /// parent already resolved (a recall, a corpus slice, today's date), so a child can be handed its
    /// slice without inheriting a live provider.
    public var context: [String: [ContextItem]]

    public init(tools: [ToolDescriptor] = [], context: [String: [ContextItem]] = [:]) {
        self.tools = tools
        self.context = context
    }

    /// Menu tool names, in declaration order — the order a narrowed catalog preserves.
    public var toolNames: [String] { tools.map(\.name) }

    /// Context labels, sorted so the prompt the model sees is stable across runs.
    public var contextLabels: [String] { context.keys.sorted() }
}

/// One subagent's brief: what to do, and what it is allowed to use.
///
/// This is the `Delegate` **task type**, which is the whole trick — `Delegate` is generic over its task
/// and already seeds exactly one slot per child, so a grant rides down to each subagent through the
/// channel that already exists. No new transport, no per-child mask on the `.delegate` leaf.
///
/// The two fields are provisioned differently on purpose, following the data/actions split: context is
/// data, so the parent snapshots it **into** the brief; tools are actions that must be *called* through
/// a live provider, so the brief carries only names and the child's model step narrows itself with
/// `Model.toolAllowlist(_:)`.
///
/// - Author: Claude
public struct DelegateBrief: Codable, Sendable, Hashable {
    /// The self-contained instruction for this subagent — one part of the parent's request.
    public var instruction: String
    /// Names of the tools this subagent may see. Always a subset of the menu it was built from.
    public var toolNames: [String]
    /// The context items provisioned for this subagent, already resolved from menu labels.
    public var contextItems: [ContextItem]

    public init(instruction: String, toolNames: [String] = [], contextItems: [ContextItem] = []) {
        self.instruction = instruction
        self.toolNames = toolNames
        self.contextItems = contextItems
    }
}
