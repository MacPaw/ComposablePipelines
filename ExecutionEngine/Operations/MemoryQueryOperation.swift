//
//  MemoryQueryOperation.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Executes a `.memoryQuery` operation: decodes the query string, calls the
/// registered ``MemoryProvider``, and returns memory entries as context items.
struct MemoryQueryOperation: Sendable {

    let context: ExecutionContext

    func execute(quality: MemoryQueryQuality, queryValue: ExecutionValue) async throws -> ExecutionValue {
        let query = try JSONDecoder().decode(String.self, from: queryValue)
        let entries = try await context.executeMemoryQuery(query: query, quality: quality)
        let items = entries.map {
            ContextItem(
                kind: .custom("memory"),
                source: ContextSourceID(rawValue: "memory"),
                value: .string($0.text)
            )
        }
        return try JSONEncoder().encode(items)
    }
}
