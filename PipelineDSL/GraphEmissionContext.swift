//
//  GraphEmissionContext.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

@_spi(Internals) public typealias PipelineClientAction = @Sendable (Data) async throws -> Data

/// Captures `@State` reads during pipeline body evaluation so that
/// `buildEither` / `buildOptional` can inject explicit `stateGet` dependency
/// nodes into the AST at conditional boundaries.
///
/// Set up by ``Pipeline/loweredGraph()``; consumed by ``PipelineBuilder``.
final class GraphEmissionContext: @unchecked Sendable {

    @TaskLocal static var current: GraphEmissionContext?

    private struct PendingRead {
        let slotID: UUID
        let valueTypeName: String
        let debugLabel: String?
        let defaultJSON: String
    }

    private var pendingReads: [PendingRead] = []
    private var stableIDSequence: UInt64 = 0
    private(set) var clientActions: [UUID: PipelineClientAction] = [:]
    private(set) var contextProviders: [UUID: any ContextItemsProvider] = [:]
    private(set) var toolRegistry = ToolRegistry()

    init(stableIDSequence: UInt64 = 0) {
        self.stableIDSequence = stableIDSequence
    }

    var readCount: Int { pendingReads.count }

    /// Keeps state owned by composed pipelines stable across reactive graph re-emission.
    func nextStableID() -> UUID {
        let sequence = stableIDSequence & 0x0000_FFFF_FFFF_FFFF
        stableIDSequence &+= 1
        let suffix = String(format: "%012llX", sequence)
        return UUID(uuidString: "E11C0000-0000-4000-8000-\(suffix)")!
    }

    func recordRead(slotID: UUID, valueTypeName: String, debugLabel: String?, defaultJSON: String) {
        pendingReads.append(
            PendingRead(slotID: slotID, valueTypeName: valueTypeName, debugLabel: debugLabel, defaultJSON: defaultJSON)
        )
    }

    func recordClientAction(taskID: UUID, action: @escaping PipelineClientAction) {
        clientActions[taskID] = action
    }

    func recordContextProvider(_ id: UUID, provider: any ContextItemsProvider) {
        contextProviders[id] = provider
    }

    /// Registers only locally-callable tools (``ToolExecutor`` conformers).
    /// ``AgentTool`` values are skipped — their descriptors reach the graph via the model node,
    /// but they have no local implementation to register.
    func registerTools(_ tools: [any PipelineTool]) {
        for tool in tools {
            if let executor = tool as? any ToolExecutor {
                toolRegistry.register(executor)
            }
        }
    }

    /// Drain ALL pending reads (used by `buildEither`/`buildOptional` for control-flow gates).
    func drainReads() -> [PipelineGraph] {
        defer { pendingReads.removeAll() }
        return toGraphs(pendingReads)
    }

    /// Drain only reads recorded since `snapshot` (used by `Binding.set`
    /// to capture only reads from its own closure, not condition reads).
    func drainReadsSince(_ snapshot: Int) -> [PipelineGraph] {
        guard pendingReads.count > snapshot else { return [] }
        let slice = Array(pendingReads[snapshot...])
        pendingReads.removeSubrange(snapshot...)
        return toGraphs(slice)
    }

    private func toGraphs(_ reads: some Sequence<PendingRead>) -> [PipelineGraph] {
        reads.map {
            .leaf(.executionStateGet(
                id: $0.slotID,
                valueTypeName: $0.valueTypeName,
                debugLabel: $0.debugLabel,
                defaultJSON: $0.defaultJSON
            ))
        }
    }
}
