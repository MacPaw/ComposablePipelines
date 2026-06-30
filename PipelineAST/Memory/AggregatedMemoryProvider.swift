//
//  AggregatedMemoryProvider.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Combines multiple memory providers behind one ``MemoryProvider``.
///
/// `query` fans out to all providers and returns entries in provider order,
/// de-duplicated by `id`. `add` writes to every provider. `retrieve` returns
/// the first matching entry.
public final class AggregatedMemoryProvider: MemoryProvider, @unchecked Sendable {
    private let providers: [any MemoryProvider]

    public init(_ providers: [any MemoryProvider]) {
        self.providers = providers
    }

    public func add(_ entry: MemoryEntry) async throws {
        for provider in providers {
            try await provider.add(entry)
        }
    }

    public func retrieve(id: String) async throws -> MemoryEntry? {
        for provider in providers {
            if let entry = try await provider.retrieve(id: id) {
                return entry
            }
        }
        return nil
    }

    public func query(_ text: String, quality: MemoryQueryQuality) async throws -> [MemoryEntry] {
        var seen: Set<String> = []
        var entries: [MemoryEntry] = []
        for provider in providers {
            for entry in try await provider.query(text, quality: quality) where seen.insert(entry.id).inserted {
                entries.append(entry)
            }
        }
        return entries
    }
}
