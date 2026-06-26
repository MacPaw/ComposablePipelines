//
//  Pipeline+Return.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Wraps an inner pipeline so lowering emits ``PipelineGraph/returnWith(_:)`` (pseudo-Swift: `return …`).
public struct ReturnedPipeline<Inner: Pipeline>: LeafPipeline {
    public typealias Output = Inner.Output

    public let inner: Inner

    public init(inner: Inner) {
        self.inner = inner
    }

    public var pipelineGraph: PipelineGraph {
        .returnWith(inner.pipelineGraph)
    }
}

extension Pipeline {

    /// Early exit with a JSON-encodable value (lowers to ``Just`` inside ``PipelineGraph/returnWith(_:)``).
    ///
    /// Use the enclosing pipeline type for output context, e.g. `Self.return(false)` when `Self.Output` is `Bool`.
    public static func `return`(_ value: Self.Output) -> ReturnedPipeline<Just<Self.Output>> where Self.Output: Encodable {
        ReturnedPipeline(inner: Just(value: value))
    }

    /// Early exit with a pipeline whose output matches the enclosing pipeline type’s ``Output``.
    public static func `return`<Inner: Pipeline>(_ inner: Inner) -> ReturnedPipeline<Inner> where Inner.Output == Self.Output {
        ReturnedPipeline(inner: inner)
    }

    /// Early exit; `body` is built with ``PipelineBuilder`` (the composed pipeline’s output must match ``Self.Output``).
    public static func `return`<Inner: Pipeline>(@PipelineBuilder _ body: () -> Inner) -> ReturnedPipeline<Inner>
        where Inner.Output == Self.Output {
        ReturnedPipeline(inner: body())
    }
}
