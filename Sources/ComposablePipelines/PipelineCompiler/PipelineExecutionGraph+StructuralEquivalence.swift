import Foundation

extension PipelineExecutionGraph.Operation {
    /// Discriminator for re-exec suffix drift checks (ignores payloads such as constant JSON).
    public var structuralShapeTag: String {
        switch self {
        case .guardrail: return "guardrail"
        case .model: return "model"
        case .summarize: return "summarize"
        case .stateGet: return "stateGet"
        case .stateSet: return "stateSet"
        case .clientAction: return "clientAction"
        case .contextProvide: return "contextProvide"
        case .constant: return "constant"
        }
    }
}

extension PipelineExecutionGraph {
    /// DFS order of task operations (ignores ``Task/id``).
    public func flattenedOperations() -> [Operation] {
        var out: [Operation] = []
        appendFlattened(into: &out)
        return out
    }

    private func appendFlattened(into out: inout [Operation]) {
        switch self {
        case .empty:
            break
        case .sequential(let steps):
            for step in steps { step.appendFlattened(into: &out) }
        case .parallel(let branches):
            for branch in branches { branch.appendFlattened(into: &out) }
        case .returnWith(let inner):
            inner.appendFlattened(into: &out)
        case .task(let task):
            out.append(task.operation)
        }
    }

    /// Structural equality ignoring per-task UUIDs (compares operation trees in DFS order).
    public func structurallyEqual(to other: PipelineExecutionGraph) -> Bool {
        flattenedOperations() == other.flattenedOperations()
    }

    /// Operations from the walk-task DFS sequence after skipping the first `skip` tasks.
    public func flattenedOperationsSuffix(fromSkipTaskCount skip: Int) -> ArraySlice<Operation> {
        let ops = flattenedOperations()
        return ops.dropFirst(skip)
    }
}
