//
//  ToolCall.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

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
