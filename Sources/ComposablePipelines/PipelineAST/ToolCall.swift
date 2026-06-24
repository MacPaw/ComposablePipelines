import Foundation

public struct ToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Raw JSON string containing the tool's input arguments.
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
