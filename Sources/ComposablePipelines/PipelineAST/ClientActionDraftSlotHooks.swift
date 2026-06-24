import Foundation

/// Hooks installed by the execution engine around each ``PipelineGraphLeaf/clientAction`` call so
/// transport code (e.g. OpenAI SSE) can push **draft** slot updates without referencing
/// ``ExecutionContext`` from ``ComposablePipelines``.
public enum ClientActionDraftSlotHooks {
    @TaskLocal public static var publishHandler: (@Sendable (UUID, Data, String) async -> Void)?

    /// Forwards JSON slot bytes to the active handler (no-op when the engine did not install one).
    public static func publish(slotID: UUID, value: Data, valueTypeName: String = "String") async {
        guard let publishHandler else { return }
        await publishHandler(slotID, value, valueTypeName)
    }

    public static func withPublishHandler<R>(
        _ handler: (@Sendable (UUID, Data, String) async -> Void)?,
        operation: () async throws -> R
    ) async rethrows -> R {
        try await Self.$publishHandler.withValue(handler, operation: operation)
    }
}
