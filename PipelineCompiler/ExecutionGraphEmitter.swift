//
//  ExecutionGraphEmitter.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Phase 2: Takes a `DependencyGraph`, groups independent tasks into parallel
/// blocks, and emits a `PipelineExecutionGraph`.
struct ExecutionGraphEmitter {

    private let optimizations: PipelineCompiler.Optimizations
    private let logger: PipelineLog

    init(optimizations: PipelineCompiler.Optimizations = .default, logger: PipelineLog = .none) {
        self.optimizations = optimizations
        self.logger = logger.subLogger("execution-graph-emitter")
    }

    func emit(from dependencyGraph: borrowing DependencyGraph) -> PipelineExecutionGraph {
        logger.log(.verbose, "emitting execution graph from \(dependencyGraph.nodes.count) nodes")

        if optimizations.contains(.parallelize) {
            let levels = topologicalLevels(in: dependencyGraph)
            logger.log(.verbose, "topological sort: \(levels.count) levels (\(levels.map(\.count)))")
            return assembleLevels(levels)
        } else {
            return assembleSequential(dependencyGraph.nodes)
        }
    }

    // MARK: - Kahn's algorithm with virtual gate barriers — O(V + E)

    private func topologicalLevels(in graph: borrowing DependencyGraph) -> [[DependencyGraph.Node]] {
        let n = graph.nodes.count
        guard n > 0 else { return [] }

        let idToIndex = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($1.id, $0) })
        let gateSet = Set(graph.gateIndices)
        let adjSuccessors: [UUID: Set<UUID>] = graph.adjacency.mapValues { Set($0) }

        var inDegree = [Int](repeating: 0, count: n)
        for edge in graph.edges {
            guard let toIdx = idToIndex[edge.to] else { continue }
            inDegree[toIdx] += 1
        }
        for gi in graph.gateIndices {
            let gateID = graph.nodes[gi].id
            let explicitSuccessors = adjSuccessors[gateID] ?? []
            for j in (gi + 1)..<n {
                if !explicitSuccessors.contains(graph.nodes[j].id) {
                    inDegree[j] += 1
                }
            }
        }

        var queue: [Int] = (0..<n).filter { inDegree[$0] == 0 }
        var levels: [[DependencyGraph.Node]] = []

        while !queue.isEmpty {
            let gateInQueue = queue.first(where: { gateSet.contains($0) })

            let levelIndices: [Int]
            if let gi = gateInQueue {
                levelIndices = [gi]
                queue.removeAll { $0 == gi }
            } else {
                levelIndices = queue
                queue.removeAll()
            }

            levels.append(levelIndices.map { graph.nodes[$0] })

            for idx in levelIndices {
                let nodeID = graph.nodes[idx].id

                for successorID in graph.successors(of: nodeID) {
                    guard let si = idToIndex[successorID] else { continue }
                    inDegree[si] -= 1
                    if inDegree[si] == 0 { queue.append(si) }
                }

                if gateSet.contains(idx) {
                    let explicitSuccessors = adjSuccessors[nodeID] ?? []
                    for j in (idx + 1)..<n {
                        let toID = graph.nodes[j].id
                        if !explicitSuccessors.contains(toID) {
                            inDegree[j] -= 1
                            if inDegree[j] == 0 { queue.append(j) }
                        }
                    }
                }
            }
        }

        return levels
    }

    // MARK: - Assembly

    private func assembleLevels(_ levels: [[DependencyGraph.Node]]) -> PipelineExecutionGraph {
        let steps: [PipelineExecutionGraph] = levels.compactMap { level in
            let tasks = level.map { emitAST($0.astFragment) }
            switch tasks.count {
            case 0: return nil
            case 1: return tasks[0]
            default: return .parallel(tasks)
            }
        }

        switch steps.count {
        case 0: return .empty
        case 1: return steps[0]
        default: return .sequential(steps)
        }
    }

    private func assembleSequential(_ nodes: [DependencyGraph.Node]) -> PipelineExecutionGraph {
        let steps = nodes.map { emitAST($0.astFragment) }.filter { $0 != .empty }
        switch steps.count {
        case 0: return .empty
        case 1: return steps[0]
        default: return .sequential(steps)
        }
    }

    // MARK: - AST fragment -> ExecutionGraph node

    private func emitAST(_ ast: PipelineGraph) -> PipelineExecutionGraph {
        switch ast {
        case .empty:
            return .empty

        case let .sequence(items):
            let mapped = items.map { emitAST($0) }.filter { $0 != .empty }
            switch mapped.count {
            case 0: return .empty
            case 1: return mapped[0]
            default: return .sequential(mapped)
            }

        case let .returnWith(inner):
            return .returnWith(emitAST(inner))

        case let .leaf(leaf):
            return emitLeaf(leaf)

        case let .group(_, _, content):
            return emitAST(content)
        }
    }

    private func emitLeaf(_ leaf: PipelineGraphLeaf) -> PipelineExecutionGraph {
        let operation: PipelineExecutionGraph.Operation

        switch leaf {
        case let .guardrail(rules):
            operation = .guardrail(rules: rules)

        case let .model(instructions, tools, input, outputTypeName, requirements):
            operation = .model(
                instructions: emitAST(instructions),
                tools: emitAST(tools),
                input: emitAST(input),
                outputTypeName: outputTypeName,
                requirements: requirements
            )

        case let .summarize(textBindingId, valueTypeName, maxTokens):
            operation = .summarize(slotID: textBindingId, valueTypeName: valueTypeName, maxTokens: maxTokens)

        case let .just(valueTypeName, jsonUTF8):
            operation = .constant(valueTypeName: valueTypeName, jsonUTF8: jsonUTF8)

        case let .executionStateSet(id, valueTypeName, value, debugLabel, writeKind):
            operation = .stateSet(
                slotID: id,
                valueTypeName: valueTypeName,
                value: emitAST(value),
                debugLabel: debugLabel,
                writeKind: writeKind
            )

        case let .executionStateGet(id, valueTypeName, debugLabel, defaultJSON):
            operation = .stateGet(slotID: id, valueTypeName: valueTypeName, debugLabel: debugLabel, defaultJSON: defaultJSON)

        case let .clientAction(taskID, input):
            operation = .clientAction(taskID: taskID, input: emitAST(input))

        case let .contextProvide(providerID, query):
            operation = .contextProvide(providerID: providerID, query: emitAST(query))

        case let .opaque(typeName):
            operation = .constant(valueTypeName: typeName, jsonUTF8: "{}")
        }

        return .task(.init(operation: operation))
    }
}
