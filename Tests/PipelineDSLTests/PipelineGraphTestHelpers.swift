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
            if case let .model(inst, tools, input, outName, _) = leaf {
                var lines = ["\(prefix)leaf model(output: \(outName))"]
                lines.append(contentsOf: prettyLines(inst, prefix: prefix + "  inst "))
                lines.append(contentsOf: prettyLines(tools, prefix: prefix + "  tools "))
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
        case let .guardrail(rules):
            return "leaf guardrail(\(rules))"
        case .model:
            preconditionFailure("model is formatted in prettyLines")
        case let .summarize(textBindingId, textBindingValueType, maxTokens):
            return "leaf summarize(binding: \(textBindingId.uuidString), valueType: \(textBindingValueType), maxTokens: \(maxTokens))"
        case let .just(valueTypeName, jsonUTF8):
            return "leaf just<\(valueTypeName)>(json: \(jsonUTF8))"
        case .executionStateSet:
            preconditionFailure("executionStateSet is formatted in prettyLines")
        case let .executionStateGet(id, valueTypeName, _, _):
            return "leaf executionStateGet(\(id.uuidString), \(valueTypeName))"
        case .clientAction:
            preconditionFailure("clientAction is formatted in prettyLines")
        case let .opaque(typeName):
            return "leaf opaque(\(typeName))"
        case let .contextProvide(providerID, _):
            return "leaf contextProvide(provider: \(providerID.uuidString))"
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
        case .leaf(.model(let inst, let tools, let input, _, _)):
            return containsSummarizeLeaf(
                textBindingId: textBindingId,
                textBindingValueType: textBindingValueType,
                maxTokens: maxTokens,
                in: inst
            )
                || containsSummarizeLeaf(
                    textBindingId: textBindingId,
                    textBindingValueType: textBindingValueType,
                    maxTokens: maxTokens,
                    in: tools
                )
                || containsSummarizeLeaf(
                    textBindingId: textBindingId,
                    textBindingValueType: textBindingValueType,
                    maxTokens: maxTokens,
                    in: input
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
        case .leaf(.model(let inst, let tools, let input, _, _)):
            return containsOpaqueLeaf(typeName, in: inst)
                || containsOpaqueLeaf(typeName, in: tools)
                || containsOpaqueLeaf(typeName, in: input)
        case .leaf(.clientAction(_, let input)):
            return containsOpaqueLeaf(typeName, in: input)
        default:
            return false
        }
    }
}
