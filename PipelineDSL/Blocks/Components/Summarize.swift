//
//  Summarize.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// Predicate: current bound text is non-empty (use with ``Guard`` before ``Summarize``); pass ``State<String>``.
public struct NonEmptyText: BooleanLeaf {
    public typealias Output = Bool

    public var text: Binding<String>

    public init(text: Binding<String>) {
        self.text = text
    }
}

/// Trims or condenses text in a typed execution slot (payload on the remote runner).
///
/// Graph recording uses ``State/id`` and ``State/valueTypeName``.
public struct Summarize: LeafPipeline {
    public typealias Output = String

    public var text: Binding<String>
    public var maxTokens: Int

    public init(text: Binding<String>, maxTokens: Int) {
        self.text = text
        self.maxTokens = maxTokens
    }
}

extension Summarize {
    public var pipelineGraph: PipelineGraph {
        .leaf(
            .summarize(
                textBindingId: text.id,
                textBindingValueType: text.valueTypeName,
                maxTokens: maxTokens
            )
        )
    }
}

extension NonEmptyText {
    public var pipelineGraph: PipelineGraph {
        .leaf(.opaque(typeName: "NonEmptyText"))
    }
}
