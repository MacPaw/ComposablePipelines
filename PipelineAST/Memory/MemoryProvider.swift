//
//  MemoryProvider.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Quality-of-service hint for memory queries.
public enum MemoryQueryQuality: String, Codable, Sendable, Hashable {
    case quick
    case full
    case precise
}

/// A single entry stored in, or retrieved from, memory.
public struct MemoryEntry: Codable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let metadata: [String: JSONValue]

    public init(id: String, text: String, metadata: [String: JSONValue] = [:]) {
        self.id = id
        self.text = text
        self.metadata = metadata
    }
}

/// Entity extracted from input text by a memory-capable model.
public struct MemoryEntity: Codable, Hashable, Sendable {
    public let key: String
    public let value: String
    public let score: Double
    public let start: Int
    public let end: Int

    public init(key: String, value: String, score: Double, start: Int, end: Int) {
        self.key = key
        self.value = value
        self.score = score
        self.start = start
        self.end = end
    }
}

public struct MemoryEntities: Codable, Hashable, Sendable {
    public let entities: [MemoryEntity]

    public init(entities: [MemoryEntity]) {
        self.entities = entities
    }
}

/// Structured fact suitable for memory storage or further pipeline processing.
public struct MemoryItem: Codable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let value: JSONValue
    public let metadata: [String: JSONValue]

    public init(
        id: String,
        key: String,
        value: JSONValue,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.metadata = metadata
    }
}

/// Relevant structured memory facts extracted from input.
public struct MemoryItems: Codable, Hashable, Sendable {
    public let items: [MemoryItem]

    public init(items: [MemoryItem]) {
        self.items = items
    }
}

/// Structured output for deciding what durable information should be stored.
///
/// A model can return an empty `entries` array when the input contains nothing
/// worth remembering.
public struct MemoryWritePlan: Codable, Hashable, Sendable {
    public let entries: [MemoryEntry]

    public init(entries: [MemoryEntry]) {
        self.entries = entries
    }
}

/// Contract for any memory backing store.
public protocol MemoryProvider: Sendable {
    func add(_ entry: MemoryEntry) async throws
    func retrieve(id: String) async throws -> MemoryEntry?
    func query(_ text: String, quality: MemoryQueryQuality) async throws -> [MemoryEntry]
}
