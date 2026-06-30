//
//  Pipeline.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
@_exported import PipelineAST

/// Pipelines name their ``Output`` type. Components that accept nested pipelines, such as
/// ``Model/input(_:)``, use that output as typed runtime input.
///
/// By default ``Output`` is ``Body.Output``: for a ``PipelineBuilder`` block, that is the **last** step’s output
/// (see ``PipelinePair``). Types whose ``body`` is not a real builder product (e.g. ``Leaf``, ``PipelinePair``)
/// usually pin ``Output`` explicitly.
///
/// Each pipeline lowers to a ``PipelineGraph`` via ``ASTNodeRepresentable/pipelineGraph``.
public protocol Pipeline: CustomStringConvertible, ASTNodeRepresentable, PipelineConvertible {
    associatedtype Body: Pipeline
    associatedtype Output = Body.Output
    @PipelineBuilder var body: Self.Body { get }
}

/// Predicate-shaped pipeline (``Output`` is ``Bool``).
public protocol BooleanPipeline: Pipeline where Output == Bool {}

/// Structural control-flow nodes (e.g. ``If``, ``Guard``); composed in the builder like other steps.
public protocol PipelineStructuralNode: Pipeline {}

/// Marker protocol for leaf pipelines that have no body.
public protocol LeafPipeline: Pipeline {}
public extension LeafPipeline {
    var body: Leaf<Output> {
        Leaf<Output>()
    }
}

extension Pipeline {
    public var representedAsPipeline: any Pipeline { self }

    /// Lowers this pipeline to a ``PipelineGraph``.
    /// Sets up ``GraphEmissionContext`` so that ``State/wrappedValue`` reads during
    /// body evaluation inject explicit `stateGet` dependency nodes at conditional
    /// boundaries (`if`/`switch`).
    public func loweredGraph() -> PipelineGraph {
        lowered().graph
    }

    @_spi(Internals) public func loweredGraphWithClientActions() -> (graph: PipelineGraph, clientActions: [UUID: PipelineClientAction]) {
        let result = lowered()
        return (result.graph, result.clientActions)
    }

    /// Lower this pipeline to its graph plus all side-channel registries needed to
    /// run it: client actions, context providers, and context renderers. Concrete
    /// callbacks/instances are stored here keyed by `UUID`; the graph itself
    /// carries only those UUIDs.
    public func lowered() -> LoweredPipeline {
        let context = GraphEmissionContext()
        let epoch = ExecutionContext.current?.committedEpoch ?? 0
        let graph = GraphEmissionContext.$current.withValue(context) {
            ExecutionContext.$executionEpoch.withValue(epoch) {
                ExecutionContext.$isEmittingPipelineGraph.withValue(true) {
                    pipelineGraph
                }
            }
        }
        return LoweredPipeline(
            graph: graph,
            clientActions: context.clientActions,
            contextProviders: context.contextProviders,
            toolRegistry: context.toolRegistry
        )
    }

    /// Pseudo-Swift from ``loweredGraph()`` — `print("\(pipeline)")` uses ``description``.
    public var pseudoSwiftDescription: String {
        loweredGraph().pseudoSwiftDescription
    }

    public var description: String {
        pseudoSwiftDescription
    }

    /// Lower then encode the graph (default ``JSONEncoder``).
    public func encodedLoweredGraph(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try encoder.encode(loweredGraph())
    }
}

extension Pipeline where Body: ASTNodeRepresentable {
    public var pipelineGraph: PipelineGraph {
        if GraphEmissionContext.current != nil {
            return body.pipelineGraph
        }
        let context = GraphEmissionContext()
        let epoch = ExecutionContext.current?.committedEpoch ?? 0
        return GraphEmissionContext.$current.withValue(context) {
            ExecutionContext.$executionEpoch.withValue(epoch) {
                ExecutionContext.$isEmittingPipelineGraph.withValue(true) {
                    body.pipelineGraph
                }
            }
        }
    }
}

extension LeafPipeline {
    /// Unknown leaf types lower to ``PipelineGraphLeaf/opaque(typeName:)``.
    public var pipelineGraph: PipelineGraph {
        .leaf(.opaque(typeName: String(describing: Self.self)))
    }
}

public struct LoweredPipeline {
    public let graph: PipelineGraph
    public let clientActions: [UUID: @Sendable (Data) async throws -> Data]
    public let contextProviders: [UUID: any ContextItemsProvider]
    public let toolRegistry: ToolRegistry

    public init(
        graph: PipelineGraph,
        clientActions: [UUID: @Sendable (Data) async throws -> Data],
        contextProviders: [UUID: any ContextItemsProvider],
        toolRegistry: ToolRegistry = ToolRegistry()
    ) {
        self.graph = graph
        self.clientActions = clientActions
        self.contextProviders = contextProviders
        self.toolRegistry = toolRegistry
    }
}
