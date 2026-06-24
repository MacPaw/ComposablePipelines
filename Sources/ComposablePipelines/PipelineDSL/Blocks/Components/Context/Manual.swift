//
//  Manual.swift
//  elix-toolchain
//
//  Created on 12.05.2026.
//

import Foundation
import PipelineAST

/// Emits a literal `[ContextItem]` as the leaf's output. Used for tests,
/// fixtures, and "always include these items" cases where retrieval is not
/// needed.
///
/// Lowers to the same constant-value leaf as ``Just`` — the array is encoded
/// into the graph at lowering time.
///
/// Example:
/// ```swift
/// $ctx.set { Manual([ContextItem(kind: "memo", source: "ltm", value: "hi")]) }
/// ```
public struct Manual: LeafPipeline {
    public typealias Output = [ContextItem]

    public let items: [ContextItem]

    public init(_ items: [ContextItem]) {
        self.items = items
    }
}

extension Manual {
    public var pipelineGraph: PipelineGraph {
        // Delegate to Just's constant-leaf lowering. The engine reads the
        // bytes back as [ContextItem] when whatever consumes this output
        // decodes its slot.
        Just(value: items).pipelineGraph
    }
}
