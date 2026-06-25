//
//  PipelineExecutionGraph+DropPrefix.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

extension PipelineExecutionGraph {
    /// Drops the first `count` **surface task ordinals** from the graph, using the same
    /// branch-major DFS order as the executor’s walk-ordinal allocation.
    ///
    /// This is used for cursor-based re-execution where the client returns only the suffix
    /// beyond a `(epoch, offset)` cursor.
    public func droppingFirstSurfaceTasks(_ count: Int) -> PipelineExecutionGraph {
        guard count > 0 else { return self }
        let (g, _) = dropPrefixTasks(remaining: count)
        return g.simplified()
    }

    private func dropPrefixTasks(remaining: Int) -> (PipelineExecutionGraph, Int) {
        guard remaining > 0 else { return (self, 0) }

        switch self {
        case .empty:
            return (.empty, remaining)

        case .task:
            return (.empty, max(0, remaining - 1))

        case .returnWith(let inner):
            let (dropped, r) = inner.dropPrefixTasks(remaining: remaining)
            if case .empty = dropped { return (.empty, r) }
            return (.returnWith(dropped), r)

        case .sequential(let steps):
            var r = remaining
            var out: [PipelineExecutionGraph] = []
            out.reserveCapacity(steps.count)
            for step in steps {
                if r == 0 {
                    out.append(step)
                    continue
                }
                let (dropped, nextR) = step.dropPrefixTasks(remaining: r)
                r = nextR
                out.append(dropped)
            }
            return (.sequential(out).simplified(), r)

        case .parallel(let branches):
            var r = remaining
            var out: [PipelineExecutionGraph] = []
            out.reserveCapacity(branches.count)
            for branch in branches {
                if r == 0 {
                    out.append(branch)
                    continue
                }
                let (dropped, nextR) = branch.dropPrefixTasks(remaining: r)
                r = nextR
                out.append(dropped)
            }
            return (.parallel(out).simplified(), r)
        }
    }

    private func simplified() -> PipelineExecutionGraph {
        switch self {
        case .empty, .task:
            return self

        case .returnWith(let inner):
            let s = inner.simplified()
            if case .empty = s { return .empty }
            return .returnWith(s)

        case .sequential(let steps):
            let simplified = steps
                .map { $0.simplified() }
                .filter { if case .empty = $0 { return false }; return true }
            switch simplified.count {
            case 0: return .empty
            case 1: return simplified[0]
            default: return .sequential(simplified)
            }

        case .parallel(let branches):
            let simplified = branches
                .map { $0.simplified() }
                .filter { if case .empty = $0 { return false }; return true }
            switch simplified.count {
            case 0: return .empty
            case 1: return simplified[0]
            default: return .parallel(simplified)
            }
        }
    }
}

