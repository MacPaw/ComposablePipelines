import Foundation

/// Identity of the in-process model to invoke via ``ResourceHeap/modelProvider``.
public struct ModelConfiguration: Sendable, Hashable {
    public let modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }

    public static func engine(modelID: String) -> ModelConfiguration {
        ModelConfiguration(modelID: modelID)
    }
}
