//
//  PipelineGraphTestHelpers.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
@testable import PipelineDSL

enum PipelineGraphTestHelpers {

    static func prettyPrint(_ graph: PipelineGraph) -> String {
        prettyLines(graph, prefix: "").joined(separator: "\n")
    }

    /// UUID-agnostic structural rendering: identical to ``prettyPrint(_:)`` but with every
    /// UUID replaced by `<id>`, so two pipelines that differ only in their (randomly assigned)
    /// slot / task ids compare equal. Use when comparing two separate fixture structs.
    static func shape(of graph: PipelineGraph) -> String {
        let rendered = prettyPrint(graph)
        let uuid = #/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#
        return rendered.replacing(uuid, with: "<id>")
    }

    private static func prettyLines(_ graph: PipelineGraph, prefix: String) -> [String] {
        switch graph {
        case .empty:
            return ["\(prefix)empty"]
        case let .sequence(items):
            var lines = ["\(prefix)sequence(\(items.count))"]
            for (i, item) in items.enumerated() {
                lines.append(contentsOf: prettyLines(item, prefix: prefix + "  [\(i)] "))
            }
            return lines
        case let .returnWith(expr):
            var lines = ["\(prefix)return"]
            lines.append(contentsOf: prettyLines(expr, prefix: prefix + "  "))
            return lines
        case let .group(sequential, gate, content):
            var lines = ["\(prefix)group(sequential: \(sequential), gate: \(gate))"]
            lines.append(contentsOf: prettyLines(content, prefix: prefix + "  "))
            return lines
        case let .loop(content):
            var lines = ["\(prefix)loop"]
            lines.append(contentsOf: prettyLines(content, prefix: prefix + "  "))
            return lines
        case let .leaf(leaf):
            if case let .executionStateSet(id, valueTypeName, value, _, _) = leaf {
                var lines = ["\(prefix)leaf executionStateSet(\(id.uuidString), \(valueTypeName))"]
                lines.append(contentsOf: prettyLines(value, prefix: prefix + "  value "))
                return lines
            }
            if case let .model(config, arguments) = leaf {
                let keys = arguments.keys.sorted().joined(separator: ", ")
                return ["\(prefix)leaf model(output: \(config.outputTypeName), args: [\(keys)])"]
            }
            if case let .modelInput(config, arguments, input) = leaf {
                let keys = arguments.keys.sorted().joined(separator: ", ")
                var lines = ["\(prefix)leaf modelInput(output: \(config.outputTypeName), args: [\(keys)])"]
                lines.append(contentsOf: prettyLines(input, prefix: prefix + "  input "))
                return lines
            }
            if case let .clientAction(taskID, input) = leaf {
                var lines = ["\(prefix)leaf clientAction(\(taskID.uuidString))"]
                lines.append(contentsOf: prettyLines(input, prefix: prefix + "  input "))
                return lines
            }
            return ["\(prefix)\(prettyLeaf(leaf))"]
        }
    }

    private static func prettyLeaf(_ leaf: PipelineGraphLeaf) -> String {
        switch leaf {
        case .model:
            preconditionFailure("model is formatted in prettyLines")
        case .modelInput:
            preconditionFailure("modelInput is formatted in prettyLines")
        case let .summarize(textBindingId, textBindingValueType, maxTokens):
            return "leaf summarize(binding: \(textBindingId.uuidString), valueType: \(textBindingValueType), maxTokens: \(maxTokens))"
        case let .just(valueTypeName, jsonUTF8):
            return "leaf just<\(valueTypeName)>(json: \(jsonUTF8))"
        case .executionStateSet:
            preconditionFailure("executionStateSet is formatted in prettyLines")
        case let .executionStateGet(id, valueTypeName, _, _):
            return "leaf executionStateGet(\(id.uuidString), \(valueTypeName))"
        case let .executionStateFrozenSet(id, valueTypeName, _, _):
            return "leaf executionStateFrozenSet(\(id.uuidString), \(valueTypeName))"
        case .clientAction:
            preconditionFailure("clientAction is formatted in prettyLines")
        case let .opaque(typeName):
            return "leaf opaque(\(typeName))"
        case let .combine(parts):
            return "leaf combine(\(parts.count))"
        case let .contextProvide(providerID, _):
            return "leaf contextProvide(provider: \(providerID.uuidString))"
        case let .memoryQuery(quality, _):
            return "leaf memoryQuery(quality: \(quality.rawValue))"
        case .memoryStore:
            return "leaf memoryStore"
        case .router:
            return "leaf router"
        case .dagPlan:
            return "leaf dagPlan"
        case .relevanceRank:
            return "leaf relevanceRank"
        }
    }

    static func containsSummarizeLeaf(
        textBindingId: UUID,
        textBindingValueType: String,
        maxTokens: Int,
        in graph: PipelineGraph
    ) -> Bool {
        switch graph {
        case .leaf(.summarize(let bindingId, let valueType, let tokens))
            where bindingId == textBindingId && valueType == textBindingValueType && tokens == maxTokens:
            return true
        case let .sequence(items):
            return items.contains {
                containsSummarizeLeaf(
                    textBindingId: textBindingId,
                    textBindingValueType: textBindingValueType,
                    maxTokens: maxTokens,
                    in: $0
                )
            }
        case let .returnWith(expr):
            return containsSummarizeLeaf(textBindingId: textBindingId, textBindingValueType: textBindingValueType, maxTokens: maxTokens, in: expr)
        case .leaf(.executionStateSet(_, _, let value, _, _)):
            return containsSummarizeLeaf(
                textBindingId: textBindingId,
                textBindingValueType: textBindingValueType,
                maxTokens: maxTokens,
                in: value
            )
        case .leaf(.clientAction(_, let input)):
            return containsSummarizeLeaf(
                textBindingId: textBindingId,
                textBindingValueType: textBindingValueType,
                maxTokens: maxTokens,
                in: input
            )
        default:
            return false
        }
    }

    static func containsOpaqueLeaf(_ typeName: String, in graph: PipelineGraph) -> Bool {
        switch graph {
        case .leaf(.opaque(let name)) where name == typeName:
            return true
        case let .sequence(items):
            return items.contains { containsOpaqueLeaf(typeName, in: $0) }
        case let .returnWith(expr):
            return containsOpaqueLeaf(typeName, in: expr)
        case .leaf(.executionStateSet(_, _, let value, _, _)):
            return containsOpaqueLeaf(typeName, in: value)
        case .leaf(.clientAction(_, let input)):
            return containsOpaqueLeaf(typeName, in: input)
        default:
            return false
        }
    }
}
