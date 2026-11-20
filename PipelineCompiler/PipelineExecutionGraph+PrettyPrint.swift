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

        case let .loopScope(body):
            var lines = ["\(p)── loop (reactive) \(String(repeating: "─", count: max(0, dividerWidth - "\(p)── loop (reactive) ".count)))"]
            lines.append(contentsOf: emit(body, indent: indent + 1))
            return lines

        case let .branch(conditionSlotID, then, otherwise):
            var lines = ["\(p)── if $\(conditionSlotID.uuidString.prefix(8)) (in-graph)"]
            lines.append(contentsOf: emit(then, indent: indent + 1))
            lines.append("\(p)── else")
            lines.append(contentsOf: emit(otherwise, indent: indent + 1))
            return lines

        case let .whileLoop(conditionSlotID, body):
            var lines = ["\(p)── while $\(conditionSlotID.uuidString.prefix(8)) (in-graph)"]
            lines.append(contentsOf: emit(body, indent: indent + 1))
            return lines
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
        case let .classify(text, task, spec):
            let pin = spec?.pinDescription.map { ", spec: \($0)" } ?? ""
            let textExpr = inlineExpr(text)
            if let textExpr {
                return ["\(pad)[\(shortID)] classify(\(task)\(pin), text: \(textExpr))"]
            }
            var lines = ["\(pad)[\(shortID)] classify(\(task)\(pin)) {"]
            lines.append(contentsOf: emit(text, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .dagPlan(query, tools, hints):
            let queryExpr = inlineExpr(query)
            if let queryExpr {
                return ["\(pad)[\(shortID)] dagPlan(tools: \(tools.count), hints: \(hints.count), query: \(queryExpr))"]
            }
            var lines = ["\(pad)[\(shortID)] dagPlan(tools: \(tools.count), hints: \(hints.count)) {"]
            lines.append(contentsOf: emit(query, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .relevanceRank(query, tools, topK):
            let queryExpr = inlineExpr(query)
            if let queryExpr {
                return ["\(pad)[\(shortID)] relevanceRank(tools: \(tools.count), topK: \(topK), query: \(queryExpr))"]
            }
            var lines = ["\(pad)[\(shortID)] relevanceRank(tools: \(tools.count), topK: \(topK)) {"]
            lines.append(contentsOf: emit(query, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .model(config, arguments):
            let keys = arguments.keys.sorted().joined(separator: ", ")
            let traitsSuffix = traitsExpr(config.traits)
            return ["\(pad)[\(shortID)] model(output: \(config.outputTypeName), traits: \(traitsSuffix), args: [\(keys)])\(allowlistSuffix(config))"]

        case let .modelInput(config, arguments, input):
            let keys = arguments.keys.sorted().joined(separator: ", ")
            let traitsSuffix = traitsExpr(config.traits)
            var lines = ["\(pad)[\(shortID)] model(output: \(config.outputTypeName), traits: \(traitsSuffix), args: [\(keys)])\(allowlistSuffix(config)) {"]
            lines.append(contentsOf: emit(input, indent: indent + 1))
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

        case let .combine(inputs):
            let inlined = inputs.map { inlineExpr($0) }
            if inlined.allSatisfy({ $0 != nil }) {
                let joined = inlined.compactMap(\.self).joined(separator: ", ")
                return ["\(pad)[\(shortID)] combine(\(joined))"]
            }
            var lines = ["\(pad)[\(shortID)] combine {"]
            for input in inputs {
                lines.append(contentsOf: emit(input, indent: indent + 1))
            }
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

        case let .memoryQuery(quality, query):
            let queryExpr = inlineExpr(query)
            if let queryExpr {
                return ["\(pad)[\(shortID)] memory(\(quality.rawValue), query: \(queryExpr))"]
            }
            var lines = ["\(pad)[\(shortID)] memory(\(quality.rawValue)) {"]
            lines.append(contentsOf: emit(query, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .memoryStore(plan, mode):
            let planExpr = inlineExpr(plan)
            if let planExpr {
                return ["\(pad)[\(shortID)] memory.store(mode: .\(mode.rawValue), plan: \(planExpr))"]
            }
            var lines = ["\(pad)[\(shortID)] memory.store(mode: .\(mode.rawValue)) {"]
            lines.append(contentsOf: emit(plan, indent: indent + 1))
            lines.append("\(pad)}")
            return lines

        case let .constant(valueTypeName, jsonUTF8):
            let truncated = jsonUTF8.count > 40
                ? String(jsonUTF8.prefix(37)) + "..."
                : jsonUTF8
            return ["\(pad)[\(shortID)] \(valueTypeName)(\(truncated))"]

        case let .delegate(child, tasksSlotID, _, budgetTotal, leafReserve, inherit):
            let header = "\(pad)[\(shortID)] delegate(tasks: \(tasksSlotID.shortID), budget: \(budgetTotal)/\(leafReserve), inherit: \(inherit.rawValue))"
            switch child {
            case let .embedded(childGraph):
                var lines = ["\(header) {"]
                lines.append(contentsOf: emit(childGraph, indent: indent + 1))
                lines.append("\(pad)}")
                return lines
            case .selfRecursion:
                return ["\(header) { self }"]
            }
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
        case let .classify(text, task, spec):
            guard let textExpr = inlineExpr(text) else { return nil }
            let pin = spec?.pinDescription.map { ", spec: \($0)" } ?? ""
            return "classify(\(task)\(pin), text: \(textExpr))"
        case let .dagPlan(query, tools, hints):
            guard let queryExpr = inlineExpr(query) else { return nil }
            return "dagPlan(tools: \(tools.count), hints: \(hints.count), query: \(queryExpr))"
        case let .relevanceRank(query, tools, topK):
            guard let queryExpr = inlineExpr(query) else { return nil }
            return "relevanceRank(tools: \(tools.count), topK: \(topK), query: \(queryExpr))"
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

    /// ` narrowedBy: [slot]` when the step's tool catalog is narrowed at runtime, else empty.
    ///
    /// Worth surfacing even though the other slot-backed fields are not printed: an allowlist changes
    /// *which tools the model was shown*, so a printed graph that omitted it would misreport the step.
    ///
    /// - Author: Claude
    static func allowlistSuffix(_ config: ModelConfig) -> String {
        guard let slotID = config.toolAllowlistSlotID else { return "" }
        return " narrowedBy: [\(slotID.shortID)]"
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

    static func pad(_ level: Int) -> String {
        String(repeating: "    ", count: level)
    }
}
