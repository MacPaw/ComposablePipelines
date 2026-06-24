import Foundation

/// Minimal recursive JSON value sufficient for tool-argument round-trips.
///
/// Use when a `Codable` field needs to carry arbitrary nested JSON (object /
/// array / scalars) instead of a fixed schema. Round-trips losslessly through
/// `JSONEncoder` / `JSONDecoder`.
///
/// Decoding is permissive: any JSON value is accepted. `Hashable` and
/// `Sendable` conformances make it safe to embed in `@State` types and other
/// pipeline DSL primitives.
public indirect enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null; return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value); return
        }
        if let value = try? container.decode(Int.self) {
            self = .integer(value); return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value); return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value); return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value); return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value); return
        }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let v):    try container.encode(v)
        case .integer(let v): try container.encode(v)
        case .double(let v):  try container.encode(v)
        case .string(let v):  try container.encode(v)
        case .array(let v):   try container.encode(v)
        case .object(let v):  try container.encode(v)
        }
    }

    /// Erase any `Encodable` value to `JSONValue` by round-tripping through JSON.
    public init<T: Encodable>(encoding value: T) {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        self = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    /// Re-encode this value as compact JSON bytes — handy when forwarding the
    /// payload to a destination that expects a `Data`-shaped JSON document
    /// (e.g., a `ToolRegistry.executeJSON(toolName:inputJSON:)` call).
    public func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }
}

// MARK: - Literal ergonomics

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .integer(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
