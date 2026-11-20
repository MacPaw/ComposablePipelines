//
//  DependencyGraph.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

extension UUID {
    public var shortID: String { String(uuidString.prefix(8)) }
}

/// Internal IR: flat dependency DAG derived from a `PipelineGraph` AST.
/// Nodes are uniquely identified; edges encode data-flow and control-flow ordering.
///
/// `~Copyable` — the graph is built once by `DependencyGraphBuilder` and borrowed
/// by `ExecutionGraphEmitter`. Preventing implicit copies avoids duplicating the
/// node/edge arrays on the builder → emitter handoff.
struct DependencyGraph: ~Copyable {
    var nodes: [Node] = []
    var edges: Set<Edge> = []
    /// Pre-built forward adjacency: `from` → `[to]`.  Built lazily by `finalize()`.
    private(set) var adjacency: [UUID: [UUID]] = [:]
    /// Indices of gate nodes. The emitter uses these as virtual barriers
    /// without materializing O(G×N) explicit edges.
    var gateIndices: [Int] = []

    /// Call once after all edges are added. Builds the adjacency list from the edge set.
    mutating func finalize() {
        adjacency.removeAll(keepingCapacity: true)
        for edge in edges {
            adjacency[edge.from, default: []].append(edge.to)
        }
    }

    func successors(of id: UUID) -> [UUID] {
        adjacency[id] ?? []
    }


}

// MARK: - Node

extension DependencyGraph {
    struct Node: Equatable {
        let id: UUID
        let astFragment: PipelineGraph
        let slotAccess: SlotAccess
        /// When true, all subsequent nodes must wait for this node to complete.
        let isGate: Bool
    }
}

// MARK: - Edge

extension DependencyGraph {
    struct Edge: Hashable {
        let from: UUID
        let to: UUID
    }
}
