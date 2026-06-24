import Foundation
import PipelineAST
import PipelineCompiler

/// Public entry for **Xcode apps / playgrounds** outside this Swift package.
///
/// `PipelineWalker` and related types are `package` and are not visible to
/// external targets; use this namespace from `PipelineDSLPlayground` (or any
/// app) to run the same engine path Oleksandr implemented.
public enum ElixEnginePlayground {

    /// Wraps a static `taskID` → handler map as ``runGraph``'s `clientActionProvider`.
    public static func clientActionProvider(
        from registry: [UUID: @Sendable (Data) async throws -> Data]
    ) -> @Sendable (UUID, Data) async throws -> Data {
        { taskID, input in
            guard let action = registry[taskID] else {
                throw ExecutionError.missingClientAction(taskID: taskID)
            }
            return try await action(input)
        }
    }

    /// Runs a compiled graph with the mock resource heap and streams stringified events.
    ///
    /// State flows through ``onStateUpdate`` (per ``ExecutionEvent/stateUpdated``, including drafts)
    /// and optional ``onCommittedBatch`` (per commit flush and per draft update batch). ``graphProvider`` receives
    /// only ``ExecutionCursor`` — return a replacement graph after your runner has applied commits.
    @discardableResult
    public static func runGraph(
        _ graph: PipelineExecutionGraph,
        initialSlots: [UUID: Data] = [:],
        clientActionProvider: (@Sendable (UUID, Data) async throws -> Data)? = nil,
        onCommittedBatch: (@Sendable ([StateUpdate]) -> Void)? = nil,
        graphProvider: (@Sendable (ExecutionCursor) -> ReexecutionGraph?)? = nil,
        onStateUpdate: (@Sendable (StateUpdate) -> Void)? = nil,
        onEvent: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Data {
        let engine = PipelineWalker(executor: MockExecutor())
        return try await engine.run(
            graph: graph,
            clientActionProvider: clientActionProvider,
            initialSlots: initialSlots,
            onCommittedBatch: onCommittedBatch,
            graphProvider: graphProvider,
            observingExecution: { event in
                if case .stateUpdated(let update) = event {
                    onStateUpdate?(update)
                }
                onEvent(String(describing: event))
            }
        )
    }
}
