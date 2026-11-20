//
//  DelegateChild.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

/// What a `.delegate` leaf runs for each subagent.
///
/// A delegate fan-out has exactly two child sources, and they use **different runtime mechanisms**:
///
/// - ``embedded(_:)`` — a concrete child graph, lowered once at build time and carried in the graph
///   (serializable, walked agent-side). This is the ordinary `Delegate { … }` / `Delegate(prototype:)`
///   form, and it can delegate **any** pipeline, including a different type (heterogeneous fan-out).
/// - ``selfRecursion`` — **no** embedded graph: each subagent re-runs the enclosing **root** graph,
///   one level deeper (a delegate of the agent itself). Embedding is impossible here — the root graph
///   *contains* this leaf, so embedding it would be a cycle — hence the marker, resolved at runtime.
///
/// Generic over the graph representation so the same type serves the AST (`PipelineGraph`) and the
/// compiled graph (`PipelineExecutionGraph`). `Equatable` / `Hashable` are **conditional** (like
/// `Optional` / `Array`), so `DelegateChild` inherits exactly the conformances its `Graph` has — the
/// enclosing leaf stays `Equatable` without forcing `Graph` to be `Hashable`.
///
/// - Author: Claude
public enum DelegateChild<Graph: Codable & Sendable>: Codable, Sendable {
    case embedded(Graph)
    case selfRecursion
}

extension DelegateChild: Equatable where Graph: Equatable {}
extension DelegateChild: Hashable where Graph: Hashable {}
