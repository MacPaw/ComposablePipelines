//
//  ForEach.swift
//  elix-toolchain
//

import Foundation
import PipelineAST

/// Collection-bounded expansion: lowers to a flat ``PipelineGraph/sequence`` of per-element bodies.
///
/// `data()` is evaluated once per emission (like ``While`` reading `condition()`), graph-read
/// dependencies from that evaluation are drained, then each element’s body is lowered in order and
/// concatenated. An empty collection lowers to ``PipelineGraph/empty``; a single element lowers to
/// that body’s graph without an extra sequence wrapper.
///
/// ## Output
///
/// `Output == Content.Output` for every element; use shared ``State`` (or similar) to pass values
/// between steps, not the collection element as a typed pipeline result.
///
/// ## Example
///
/// ```swift
/// var body: some Pipeline {
///     ForEach(data: { [1, 2, 3] }) { _ in
///         ClientTask { /* … */ }
///     }
/// }
/// ```
public struct ForEach<C: RandomAccessCollection, Content: Pipeline>: LeafPipeline {
    public typealias Output = Content.Output

    private let data: @Sendable () -> C
    private let content: @Sendable (C.Element) -> Content

    public init(
        in data: @escaping @Sendable () -> C,
        @PipelineBuilder content: @escaping @Sendable (C.Element) -> Content
    ) {
        self.data = data
        self.content = content
    }
    
    public init(
        in data: C,
        @PipelineBuilder content: @escaping @Sendable (C.Element) -> Content
    ) {
        self.data = { data }
        self.content = content
    }

    public var pipelineGraph: PipelineGraph {
        let ctx = GraphEmissionContext.current
        let snapshot = ctx?.readCount ?? 0
        let collection = data()
        _ = ctx?.drainReadsSince(snapshot)

        guard !collection.isEmpty else { return .empty }

        var graphs: [PipelineGraph] = []
        graphs.reserveCapacity(collection.count)
        for index in collection.indices {
            graphs.append(content(collection[index]).pipelineGraph)
        }

        switch graphs.count {
        case 1:
            return graphs[0]
        default:
            return .sequence(graphs)
        }
    }
}
