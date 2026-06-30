//
//  MemoryStoreOperation.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Persists a structured memory plan through the provider registered for the run.
struct MemoryStoreOperation: Sendable {
    let context: ExecutionContext

    func execute(planValue: ExecutionValue) async throws -> ExecutionValue {
        let plan = try JSONDecoder().decode(MemoryWritePlan.self, from: planValue)
        for entry in plan.entries {
            try await context.executeMemoryStore(entry)
        }
        return try JSONEncoder().encode(plan)
    }
}
