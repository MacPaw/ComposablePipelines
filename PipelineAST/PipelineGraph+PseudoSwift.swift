//
//  PipelineGraph+PseudoSwift.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Renders a ``PipelineGraph`` as readable pseudo-Swift (`if` / `guard` style, for debugging / logs).
extension PipelineGraph: CustomStringConvertible {
    public var description: String {
        pseudoSwiftDescription
    }

    public var pseudoSwiftDescription: String {
        PseudoSwiftEmitter.emit(self, indent: 0).joined(separator: "\n")
    }
}

private enum PseudoSwiftEmitter {
    static func emit(_ graph: PipelineGraph, indent: Int) -> [String] {
        let pad = indentString(indent)
        switch graph {
        case .empty:
            return ["\(pad)// (empty)"]

        case let .sequence(items):
            var lines: [String] = []
            for item in items {
                lines.append(contentsOf: emit(item, indent: indent))
            }
            return lines

        case let .returnWith(expr):
            if let leaf = singleLeaf(expr) {
                return ["\(pad)return \(leafExpression(leaf))"]
            }
            var lines = ["\(pad)return"]
            lines.append(contentsOf: emit(expr, indent: indent + 1))
            return lines

        case let .group(sequential, gate, content):
            var parts: [String] = []
            if sequential { parts.append("sequential") }
            if gate { parts.append("gate") }
            let label = parts.isEmpty ? "Group" : "Group(\(parts.joined(separator: ", ")))"
            var lines = ["\(pad)\(label) {"]
            lines.append(contentsOf: emit(content, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .loop(content):
            var lines = ["\(pad)Loop {"]
            lines.append(contentsOf: emit(content, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .leaf(leaf):
            switch leaf {
            case let .executionStateSet(id, _, valueGraph, label, _):
                let name = label ?? id.uuidString
                var lines = [
                    "\(pad)executionStateSet(\"\(name)\") {",
                ]
                lines.append(contentsOf: emit(valueGraph, indent: indent + 1))
                lines.append("\(pad)}")
                return lines
            case let .model(config, arguments):
                let escOut = config.outputTypeName
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let keys = arguments.keys.sorted().joined(separator: ", ")
                return ["\(pad)model(output: \"\(escOut)\", args: [\(keys)])"]
            case let .modelInput(config, arguments, input):
                let keys = arguments.keys.sorted().joined(separator: ", ")
                var lines = ["\(pad)model(output: \"\(config.outputTypeName)\", args: [\(keys)]) {"]
                lines.append(contentsOf: emit(input, indent: indent + 1))
                lines.append("\(pad)}")
                return lines
            default:
                return ["\(pad)\(leafExpression(leaf))"]
            }
        }
    }

    private static func singleLeaf(_ graph: PipelineGraph) -> PipelineGraphLeaf? {
        if case let .leaf(l) = graph { return l }
        return nil
    }

    private static func leafExpression(_ leaf: PipelineGraphLeaf) -> String {
        switch leaf {
        case let .model(config, arguments):
            let escOut = config.outputTypeName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let keys = arguments.keys.sorted().joined(separator: ", ")
            return "model(output: \"\(escOut)\", args: [\(keys)])"

        case let .modelInput(config, arguments, input):
            let keys = arguments.keys.sorted().joined(separator: ", ")
            let inner = emit(input, indent: 0).joined(separator: " ")
            return "model(output: \"\(config.outputTypeName)\", args: [\(keys)], input: \(inner))"

        case let .summarize(textBindingId, textBindingValueType, maxTokens):
            let escId = textBindingId.uuidString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let escType = textBindingValueType
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "summarize(textBindingId: \"\(escId)\", valueType: \"\(escType)\", maxTokens: \(maxTokens))"

        case let .just(valueTypeName, jsonUTF8):
            let esc = jsonUTF8
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "just<\(valueTypeName)>(json: \"\(esc)\")"

        case let .executionStateSet(id, _, valueGraph, label, _):
            let name = label ?? id.uuidString
            let inner = emit(valueGraph, indent: 0).joined(separator: " ")
            return "stateValue(\"\(name)\") { \(inner) }"

        case let .executionStateGet(id, _, label, _):
            let name = label ?? id.uuidString
            return "stateValue(\"\(name)\")"

        case let .opaque(typeName):
            return "\(typeName)()"
        case let .clientAction(taskID, inputGraph):
            let inner = emit(inputGraph, indent: 0).joined(separator: " ")
            return "clientAction(taskID: \"\(taskID.uuidString)\", input: \(inner))"
        case let .contextProvide(providerID, queryGraph):
            let inner = emit(queryGraph, indent: 0).joined(separator: " ")
            return "contextProvide(providerID: \"\(providerID.uuidString)\", query: \(inner))"
        case let .memoryQuery(quality, queryGraph):
            let inner = emit(queryGraph, indent: 0).joined(separator: " ")
            return "memory.recall(quality: .\(quality.rawValue), query: \(inner))"
        case let .memoryStore(planGraph):
            let inner = emit(planGraph, indent: 0).joined(separator: " ")
            return "memory.store(plan: \(inner))"
        }
    }

    private static func indentString(_ level: Int) -> String {
        String(repeating: "    ", count: level)
    }
}
