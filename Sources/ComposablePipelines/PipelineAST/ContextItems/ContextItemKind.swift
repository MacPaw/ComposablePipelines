//
//  ContextItemKind.swift
//  elix-toolchain
//
//  Created on 12.05.2026.
//

import Foundation

/// Discriminator for ``ContextItem/value``.
///
/// The three built-in cases cover the most common pipeline context shapes.
/// Fall back to ``custom(_:)`` for domain-specific kinds.
///
/// The type round-trips through JSON as a plain string — `.tool` encodes as
/// `"tool"`, `.transcriptItem` as `"transcriptItem"`, and `.custom("x")` as `"x"`.
public enum ContextItemKind: Hashable, Sendable {
    case tool
    case transcriptItem
    case custom(String)
}

// MARK: - Codable

extension ContextItemKind: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "tool":            self = .tool
        case "transcriptItem":  self = .transcriptItem
        default:                self = .custom(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .tool:             try container.encode("tool")
        case .transcriptItem:   try container.encode("transcriptItem")
        case .custom(let s):    try container.encode(s)
        }
    }
}

// MARK: - Tag name

extension ContextItemKind {
    /// Plain string used as an XML tag name and for display purposes.
    public var tagName: String {
        switch self {
        case .tool:             return "tool"
        case .transcriptItem:  return "transcriptItem"
        case .custom(let s):   return s
        }
    }
}
