//
//  SlotAccess.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Tracks which execution-state slots a `PipelineGraph` subtree reads from and writes to.
struct SlotAccess: Equatable {
    var reads: Set<UUID> = []
    var writes: Set<UUID> = []

    var isEmpty: Bool { reads.isEmpty && writes.isEmpty }

    mutating func merge(_ other: SlotAccess) {
        reads.formUnion(other.reads)
        writes.formUnion(other.writes)
    }

    /// True when `self` depends on `other` — i.e. `self` reads a slot that `other` writes.
    func dependsOn(_ other: SlotAccess) -> Bool {
        !reads.isDisjoint(with: other.writes)
    }
}

extension SlotAccess {
    /// Recursively collects all slot reads/writes from a `PipelineGraph` subtree.
    static func collect(from graph: PipelineGraph) -> SlotAccess {
        var access = SlotAccess()
        walk(graph, into: &access)
        return access
    }

    private static func walk(_ graph: PipelineGraph, into access: inout SlotAccess) {
        switch graph {
        case .empty:
            break

        case let .sequence(items):
            for item in items { walk(item, into: &access) }

        case let .returnWith(inner):
            walk(inner, into: &access)

        case let .leaf(leaf):
            walkLeaf(leaf, into: &access)

        case let .group(_, _, content):
            walk(content, into: &access)

        case let .loop(content):
            walk(content, into: &access)
        }
    }

    private static func walkLeaf(_ leaf: PipelineGraphLeaf, into access: inout SlotAccess) {
        switch leaf {
        case let .router(query, _):
            walk(query, into: &access)

        case let .dagPlan(query, _, _):
            walk(query, into: &access)

        case let .relevanceRank(query, _, _, _):
            walk(query, into: &access)

        case let .model(config, _):
            for id in config.contextItemsSlotIDs { access.reads.insert(id) }
            if let id = config.priorTurnsSlotID { access.reads.insert(id) }
            if let id = config.streamingReplySlotID { access.writes.insert(id) }

        case let .modelInput(config, _, input):
            for id in config.contextItemsSlotIDs { access.reads.insert(id) }
            if let id = config.streamingReplySlotID { access.writes.insert(id) }
            walk(input, into: &access)

        case let .summarize(textBindingId, _, _):
            access.reads.insert(textBindingId)

        case .just:
            break

        case let .executionStateSet(id, _, value, _, _):
            access.writes.insert(id)
            walk(value, into: &access)

        case let .executionStateGet(id, _, _, _):
            access.reads.insert(id)

        case let .executionStateFrozenSet(id, _, _, _):
            // Treat as a write so that the compiler preserves ordering edges (RAW/WAW) to
            // subsequent reads of the same slot — matching the semantics of the unfrozen
            // `executionStateSet` it replaced. Without this, the topological sort
            // parallelizes this node with explicit `$binding.get()` reads of the same slot.
            access.writes.insert(id)

        case let .clientAction(_, input):
            walk(input, into: &access)

        case let .combine(parts):
            for part in parts { walk(part, into: &access) }

        case let .contextProvide(_, query):
            walk(query, into: &access)

        case let .memoryQuery(_, query):
            walk(query, into: &access)

        case let .memoryStore(plan, _):
            walk(plan, into: &access)

        case .opaque:
            break
        }
    }
}
