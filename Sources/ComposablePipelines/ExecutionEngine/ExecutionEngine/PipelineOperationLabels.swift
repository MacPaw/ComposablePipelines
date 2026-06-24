//
//  PipelineOperationLabels.swift
//  elix-toolchain
//
//  Created by Oleksandr Frankiv on 23.04.2026.
//

import Foundation
import PipelineAST
import PipelineCompiler

// MARK: - Short label (used for memoization logging and trace entries)

extension PipelineExecutionGraph.Operation {
    var label: String {
        switch self {
        case .constant:     return "constant"
        case .stateGet:     return "stateGet"
        case .stateSet:     return "stateSet"
        case .model:        return "model"
        case .guardrail:    return "guardrail"
        case .summarize:    return "summarize"
        case .clientAction: return "clientAction"
        case .contextProvide: return "contextProvide"
        }
    }
}

// MARK: - Slot association

extension PipelineExecutionGraph.Operation {
    /// Slot UUID for state operations (`stateGet` / `stateSet`); `nil` for ops that
    /// don't bind a single slot. Surfaced through `StepInfo.slotID` so observers
    /// can correlate a step with its slot without re-walking the compiled graph.
    var slotID: UUID? {
        switch self {
        case let .stateGet(slotID, _, _, _): return slotID
        case let .stateSet(slotID, _, _, _, _): return slotID
        case let .summarize(slotID, _, _):   return slotID
        case .constant, .model, .guardrail, .clientAction, .contextProvide: return nil
        }
    }
}

// MARK: - Pretty label (used for verbose log output)

extension PipelineExecutionGraph.Operation {
    var prettyLabel: String {
        switch self {
        case let .guardrail(rules):
            let r = rules.map { ".\($0)" }.joined(separator: ", ")
            return "guardrail([\(r)])"
        case let .model(_, _, _, out, _):
            return "model → \(out)"
        case let .summarize(_, _, max):
            return "summarize(max: \(max))"
        case let .stateGet(slotID, _, label, _):
            if let label, !label.isEmpty { return "$\(label).get" }
            return "[\(slotID.shortID)].get"
        case let .stateSet(slotID, _, _, label, _):
            if let label, !label.isEmpty { return "$\(label).set" }
            return "[\(slotID.shortID)].set"
        case let .clientAction(id, _):
            return "clientAction(\(id.shortID))"
        case let .contextProvide(providerID, _):
            return "contextProvide(\(providerID.shortID))"
        case let .constant(type, json):
            let val = json.count > 30 ? String(json.prefix(27)) + "..." : json
            return "\(type)(\(val))"
        }
    }
}
