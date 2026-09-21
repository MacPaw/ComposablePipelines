//
//  ToolCall+ClientTask.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

extension ToolCall {
    /// Wraps this tool call in a ``ClientTask`` whose input pipeline materializes this value and whose
    /// `action` runs on the client with the same ``ToolCall`` (after JSON round-trip through the graph).
    public func clientTask<Output: Sendable & Codable & Hashable>(
        perform action: @escaping @Sendable (ToolCall) async throws -> Output
    ) -> ClientTask<ToolCall, Output> {
        let call = self
        return ClientTask {
            Just(value: call)
        } action: { _ in
            try await action(call)
        }
    }

    /// Decodes ``arguments`` as JSON and dispatches to ``ToolRegistry/executeJSON(toolName:inputJSON:)``.
    public func clientTask(executing registry: ToolRegistry) -> ClientTask<ToolCall, Data> {
        let call = self
        return ClientTask {
            Just(value: call)
        } action: { _ in
            let inputJSON = Data(call.arguments.utf8)
            return try await registry.executeJSON(toolName: call.name, inputJSON: inputJSON)
        }
    }
}
