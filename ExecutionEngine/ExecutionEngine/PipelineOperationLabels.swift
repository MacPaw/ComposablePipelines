//
//  PipelineOperationLabels.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
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
        case .modelInput:   return "model"
        case .summarize:    return "summarize"
        case .clientAction: return "clientAction"
        case .contextProvide: return "contextProvide"
        case .memoryQuery: return "memoryQuery"
        case .memoryStore: return "memoryStore"
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
        case .constant, .model, .modelInput, .clientAction, .contextProvide, .memoryQuery, .memoryStore: return nil
        }
    }
}

// MARK: - Pretty label (used for verbose log output)

extension PipelineExecutionGraph.Operation {
    var prettyLabel: String {
        switch self {
        case let .model(config, _):
            return "model → \(config.outputTypeName)"
        case let .modelInput(config, _, _):
            return "model → \(config.outputTypeName)"
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
        case let .memoryQuery(quality, _):
            return "memory(\(quality.rawValue))"
        case .memoryStore:
            return "memory.store"
        case let .constant(type, json):
            let val = json.count > 30 ? String(json.prefix(27)) + "..." : json
            return "\(type)(\(val))"
        }
    }
}
