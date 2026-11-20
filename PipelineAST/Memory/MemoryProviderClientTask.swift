//
//  MemoryProviderClientTask.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Codable request used when a remote agent calls a client-side memory provider
/// through the existing ClientTask callback channel.
public enum MemoryProviderClientTaskRequest: Codable, Sendable, Hashable {
    case add(MemoryEntry)
    case retrieve(id: String)
    case query(text: String, quality: MemoryQueryQuality)
}

/// Codable response for ``MemoryProviderClientTaskRequest``.
public enum MemoryProviderClientTaskResponse: Codable, Sendable, Hashable {
    case void
    case entry(MemoryEntry?)
    case entries([MemoryEntry])
}

public enum MemoryProviderClientTaskError: Error, Sendable, Equatable {
    case unexpectedResponse
}

/// ``MemoryProvider`` implementation that forwards calls through a client-task
/// style callback. Used by remote agents to call providers owned by the client.
public final class ClientTaskMemoryProvider: MemoryProvider, @unchecked Sendable {
    private let taskID: UUID
    private let execute: @Sendable (UUID, Data) async throws -> Data

    public init(taskID: UUID, execute: @escaping @Sendable (UUID, Data) async throws -> Data) {
        self.taskID = taskID
        self.execute = execute
    }

    public func add(_ entry: MemoryEntry) async throws {
        let response = try await request(.add(entry))
        guard case .void = response else {
            throw MemoryProviderClientTaskError.unexpectedResponse
        }
    }

    public func retrieve(id: String) async throws -> MemoryEntry? {
        let response = try await request(.retrieve(id: id))
        guard case let .entry(entry) = response else {
            throw MemoryProviderClientTaskError.unexpectedResponse
        }
        return entry
    }

    public func query(_ text: String, quality: MemoryQueryQuality) async throws -> [MemoryEntry] {
        let response = try await request(.query(text: text, quality: quality))
        guard case let .entries(entries) = response else {
            throw MemoryProviderClientTaskError.unexpectedResponse
        }
        return entries
    }

    private func request(_ request: MemoryProviderClientTaskRequest) async throws -> MemoryProviderClientTaskResponse {
        let input = try JSONEncoder().encode(request)
        let output = try await execute(taskID, input)
        return try JSONDecoder().decode(MemoryProviderClientTaskResponse.self, from: output)
    }
}
