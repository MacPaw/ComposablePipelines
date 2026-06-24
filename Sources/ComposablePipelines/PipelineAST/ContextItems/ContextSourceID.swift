//
//  ContextSourceID.swift
//  elix-toolchain
//
//  Created on 12.05.2026.
//

import Foundation

/// Identifies which provider produced a ``ContextItem``. Open enum — clients
/// define their own values via extension; the toolchain ships no built-ins.
///
/// Example (client-side):
/// ```swift
/// extension ContextSourceID {
///     static let mySlack: ContextSourceID = "slack"
/// }
/// ```
///
/// `kind` answers "what is this thing?"; `source` answers "where did it come
/// from?". One source can produce many kinds, and one kind can come from
/// many sources.
public struct ContextSourceID:
    Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}
