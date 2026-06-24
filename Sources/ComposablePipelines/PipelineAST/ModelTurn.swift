import Foundation

/// One turn of a model's response — either a final reply or a set of tool calls.
///
/// Used as the provider's return type and as a first-class pipeline output type
/// (`Model<Input, ModelTurn>`) for pipelines that need to inspect tool calls.
public struct ModelTurn: Codable, Hashable, Sendable {
    public let reply: String?
    public let toolCalls: [ToolCall]?

    public init(reply: String? = nil, toolCalls: [ToolCall]? = nil) {
        self.reply = reply
        self.toolCalls = toolCalls
    }
}
