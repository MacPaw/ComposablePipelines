import Foundation

/// A typed model argument. Each built-in case has a fixed string key used as the dictionary key
/// in `ModelArguments`. Use `.custom(key:value:)` for arguments not covered by built-in cases.
public enum ModelArgument: Codable, Sendable, Equatable {

    case systemPrompt(String)
    case message(JSONValue)
    case tools([ToolDescriptor])
    case temperature(Double)
    case maxTokens(Int)
    case contextItems([ContextItem])
    case custom(key: String, value: JSONValue)

    public var key: String {
        switch self {
        case .systemPrompt:       return "systemPrompt"
        case .message:            return "message"
        case .tools:              return "tools"
        case .temperature:        return "temperature"
        case .maxTokens:          return "maxTokens"
        case .contextItems:       return "contextItems"
        case .custom(let k, _):   return k
        }
    }

    public var value: JSONValue {
        switch self {
        case .systemPrompt(let v):  return .string(v)
        case .message(let v):       return v
        case .tools(let v):         return JSONValue(encoding: v)
        case .temperature(let v):   return .double(v)
        case .maxTokens(let v):     return .integer(v)
        case .contextItems(let v):  return JSONValue(encoding: v)
        case .custom(_, let v):     return v
        }
    }
}

/// Arguments passed to a model step, keyed by each argument's stable string key.
public typealias ModelArguments = [String: ModelArgument]
