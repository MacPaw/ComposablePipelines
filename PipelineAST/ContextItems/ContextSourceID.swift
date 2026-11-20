//
//  ContextSourceID.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
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
