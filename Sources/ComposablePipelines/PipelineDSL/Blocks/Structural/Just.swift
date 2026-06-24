//
//  Just.swift
//  EneyLocal
//
//  Created by Maxim Kotliar on 10.04.2026.
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
