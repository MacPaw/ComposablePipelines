//
//  Just.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

public struct Just<Output>: LeafPipeline where Output: Encodable {
    public let value: Output

    public init(value: Output) {
        self.value = value
    }
}

extension Just {
    public var pipelineGraph: PipelineGraph {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value)
            let jsonUTF8 = String(decoding: data, as: UTF8.self)
            return .leaf(
                .just(
                    valueTypeName: String(describing: Output.self),
                    jsonUTF8: jsonUTF8
                )
            )
        } catch {
            return .leaf(.opaque(typeName: "Just<\(String(describing: Output.self))>"))
        }
    }
}
