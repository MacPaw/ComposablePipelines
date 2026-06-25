//
//  PipelineExecutionGraph+PrettyPrint.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

extension PipelineExecutionGraph: CustomStringConvertible {
    public var description: String {
        Printer.emit(self, indent: 0).joined(separator: "\n")
    }
}

private enum Printer {

    static let dividerWidth = 48

    static func emit(_ graph: PipelineExecutionGraph, indent: Int) -> [String] {
        let p = pad(indent)
        switch graph {
        case .empty:
            return ["\(p)// (empty)"]

        case let .sequential(steps):
            var lines: [String] = []
            for (i, step) in steps.enumerated() {
                let label: String
                if case .parallel = step {
                    label = "\(p)── \(i + 1) ── parallel "
                } else {
                    label = "\(p)── \(i + 1) "
                }
                let ruler = label + String(
                    repeating: "─",
                    count: max(0, dividerWidth - label.count)
                )
                if i > 0 { lines.append("") }
                lines.append(ruler)
                if case let .parallel(tasks) = step {
                    lines.append(contentsOf: emitParallelLanes(tasks, indent: indent))
                } else {
                    lines.append(contentsOf: emit(step, indent: indent))
                }
            }
            return lines

        case let .parallel(tasks):
            var lines = ["\(p)── parallel \(String(repeating: "─", count: max(0, dividerWidth - "\(p)── parallel ".count)))"]
            lines.append(contentsOf: emitParallelLanes(tasks, indent: indent))
            return lines

        case let .returnWith(inner):
            let innerExpr = inlineExpr(inner)
            if let innerExpr {
                return ["\(p)return \(innerExpr)"]
            }
            var lines = ["\(p)return {"]
            lines.append(contentsOf: emit(inner, indent: indent + 1))
            lines.append("\(p)}")
            return lines

        case let .task(task):
            return emitTask(task, indent: indent)
        }
    }

    // MARK: - Parallel lanes

    static func emitParallelLanes(_ tasks: [PipelineExecutionGraph], indent: Int) -> [String] {
        let p = pad(indent)
        var lines: [String] = []
        for (i, task) in tasks.enumerated() {
            let connector = (i < tasks.count - 1) ? "├" : "└"
            let gutter    = (i < tasks.count - 1) ? "│" : " "

            let taskLines = emit(task, indent: 0)
            for (j, line) in taskLines.enumerated() {
                let prefix = (j == 0) ? "\(p)\(connector)─ " : "\(p)\(gutter)  "
                lines.append(prefix + line)
            }
            if i < tasks.count - 1 {
                lines.append("\(p)│")
            }
        }
        return lines
    }

    // MARK: - Task rendering

    static func emitTask(_ task: PipelineExecutionGraph.Task, indent: Int) -> [String] {
        let pad = pad(indent)
        let shortID = task.id.uuidString.prefix(8).description

        switch task.operation {
        case let .guardrail(rules):
            let r = rules.map { ".\($0)" }.joined(separator: ", ")
            return ["\(pad)[\(shortID)] guardrail(rules: [\(r)])"]

        case let .model(instructions, tools, input, outputTypeName, requirements):
            let requirementsSuffix = requirements.map { ", requirements: \(requirementsExpr($0))" } ?? ""
            var lines = ["\(pad)[\(shortID)] model(output: \(outputTypeName)\(requirementsSuffix)) {"]
            lines.append("\(pad)    instructions:")
            lines.append(contentsOf: emit(instructions, indent: indent + 2))
            if tools != .empty {
                lines.append("\(pad)    tools:")
                lines.append(contentsOf: emit(tools, indent: indent + 2))
            }
            lines.append("\(pad)    input:")
            lines.append(contentsOf: emit(input, indent: indent + 2))
            lines.append("\(pad)}")
            return lines

        case let .summarize(slotID, _, maxTokens):
            return ["\(pad)[\(shortID)] summarize(slot: \(slotID.shortID), maxTokens: \(maxTokens))"]

        case let .stateGet(slotID, _, debugLabel, _):
            let slotTag = Self.stateSlotTag(slotID: slotID, debugLabel: debugLabel)
            return ["\(pad)[\(shortID)] \(slotTag).get"]

        case let .stateSet(slotID, _, value, debugLabel, _):
            let slotTag = Self.stateSlotTag(slotID: slotID, debugLabel: debugLabel)
            let valueExpr = inlineExpr(value)
            if let valueExpr {
                return ["\(pad)[\(shortID)] \(slotTag).set(\(valueExpr))"]
            }
            var lines = ["\(pad)[\(shortID)] \(slotTag).set {"]
            lines.append(contentsOf: emit(value, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .clientAction(taskID, input):
            let inputExpr = inlineExpr(input)
            if let inputExpr {
                return ["\(pad)[\(shortID)] clientAction(\(taskID.shortID), input: \(inputExpr))"]
            }
            var lines = ["\(pad)[\(shortID)] clientAction(\(taskID.shortID)) {"]
            lines.append(contentsOf: emit(input, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .contextProvide(providerID, query):
            let queryExpr = inlineExpr(query)
            if let queryExpr {
                return ["\(pad)[\(shortID)] contextProvide(\(providerID.shortID), query: \(queryExpr))"]
            }
            var lines = ["\(pad)[\(shortID)] contextProvide(\(providerID.shortID)) {"]
            lines.append(contentsOf: emit(query, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .constant(valueTypeName, jsonUTF8):
            let truncated = jsonUTF8.count > 40
                ? String(jsonUTF8.prefix(37)) + "..."
                : jsonUTF8
            return ["\(pad)[\(shortID)] \(valueTypeName)(\(truncated))"]
        }
    }

    // MARK: - Inline expressions (single-line when simple enough)

    static func inlineExpr(_ graph: PipelineExecutionGraph) -> String? {
        switch graph {
        case .empty:
            return "(empty)"
        case let .task(task):
            return inlineTask(task)
        default:
            return nil
        }
    }

    static func inlineTask(_ task: PipelineExecutionGraph.Task) -> String? {
        switch task.operation {
        case let .stateGet(slotID, _, debugLabel, _):
            return "\(Self.stateSlotTag(slotID: slotID, debugLabel: debugLabel)).get"
        case let .constant(valueTypeName, jsonUTF8):
            let truncated = jsonUTF8.count > 30
                ? String(jsonUTF8.prefix(27)) + "..."
                : jsonUTF8
            return "\(valueTypeName)(\(truncated))"
        case let .guardrail(rules):
            let r = rules.map { ".\($0)" }.joined(separator: ", ")
            return "guardrail([\(r)])"
        default:
            return nil
        }
    }

    // MARK: - Helpers

    /// `$name` when `debugLabel` is present; otherwise `[uuidPrefix]` for logs without a property name.
    static func stateSlotTag(slotID: UUID, debugLabel: String?) -> String {
        if let debugLabel, !debugLabel.isEmpty { return "$\(debugLabel)" }
        return "[\(slotID.shortID)]"
    }

    static func requirementsExpr(_ requirements: ModelSelectionRequirements) -> String {
        var parts: [String] = []
        if let purpose = requirements.purpose {
            parts.append("purpose: .\(purpose.rawValue)")
        }
        if let backend = requirements.backend {
            parts.append("backend: \(backendExpr(backend))")
        }
        if !requirements.traits.isEmpty {
            parts.append("traits: \(traitsExpr(requirements.traits))")
        }
        if let spec = requirements.spec {
            parts.append("spec: \(specExpr(spec))")
        }
        return ".init(\(parts.joined(separator: ", ")))"
    }

    static func backendExpr(_ backend: ModelBackend) -> String {
        switch backend {
        case .mlx:
            return ".mlx"
        case .custom(let name):
            return ".custom(\"\(name)\")"
        }
    }

    static func traitsExpr(_ traits: ModelSelectionTraits) -> String {
        var values: [String] = []
        if traits.contains(.quick) { values.append(".quick") }
        if traits.contains(.lowMemory) { values.append(".lowMemory") }
        if traits.contains(.lowCost) { values.append(".lowCost") }
        if traits.contains(.localOnly) { values.append(".localOnly") }
        if traits.contains(.instruct) { values.append(".instruct") }
        if traits.contains(.reasoning) { values.append(".reasoning") }
        if traits.contains(.streaming) { values.append(".streaming") }
        return "[\(values.joined(separator: ", "))]"
    }

    static func specExpr(_ spec: ModelSpecDescriptor) -> String {
        var parts: [String] = []
        if let sourceID = spec.sourceID {
            parts.append("sourceID: \"\(sourceID)\"")
        }
        if let revision = spec.revision {
            parts.append("revision: \"\(revision)\"")
        }
        if !spec.additionalFiles.isEmpty {
            let files = spec.additionalFiles.map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("additionalFiles: [\(files)]")
        }
        return ".init(\(parts.joined(separator: ", ")))"
    }

    static func pad(_ level: Int) -> String {
        String(repeating: "    ", count: level)
    }
}
