//
//  MemoryStoreOperation.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Persists a structured memory plan through the provider registered for the run.
struct MemoryStoreOperation: Sendable {
    let context: ExecutionContext

    func execute(planValue: ExecutionValue, mode: MemoryStoreMode = .sync) async throws -> ExecutionValue {
        let plan = try JSONDecoder().decode(MemoryWritePlan.self, from: planValue)

        switch mode {
        case .sync:
            let entryCount = plan.entries.count
            await context.emit(.memoryStoreStarted(entryCount: entryCount, mode: .sync))
            do {
                try await store(plan)
                await context.emit(.memoryStoreCompleted(entryCount: entryCount, mode: .sync, errorDescription: nil))
            } catch {
                await context.emit(.memoryStoreCompleted(entryCount: entryCount, mode: .sync, errorDescription: "\(error)"))
                throw error
            }
        case .async:
            // Async store is best-effort — silently skip when no memory provider is configured.
            // Extract the provider and observer *before* spawning the task so the detached task
            // holds no reference back to the engine actor. Calling actor methods from a concurrent
            // Task interleaves with the main walk's actor calls (e.g. StateSetOperation's three
            // sequential awaits) and can corrupt pendingSkipCountForNextWalk / needsReexecution.
            guard let provider = await context.memoryProviderForAsync() else {
                return try JSONEncoder().encode(plan)
            }
            let entries = plan.entries
            let entryCount = entries.count
            let observer = await context.observer
            await context.emit(.memoryStoreStarted(entryCount: entryCount, mode: mode))
            Task.detached {
                do {
                    for entry in entries { try await provider.add(entry) }
                    observer?(.memoryStoreCompleted(entryCount: entryCount, mode: .async, errorDescription: nil))
                } catch {
                    observer?(.memoryStoreCompleted(entryCount: entryCount, mode: .async, errorDescription: "\(error)"))
                }
            }
        }
        return try JSONEncoder().encode(plan)
    }

    private func store(_ plan: MemoryWritePlan) async throws {
        for entry in plan.entries {
            try await context.executeMemoryStore(entry)
        }
    }
}
