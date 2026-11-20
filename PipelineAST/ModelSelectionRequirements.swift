//
//  ModelSelectionRequirements.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

public struct ModelSelectionRequirements: Codable, Equatable, Hashable, Sendable {
    public static let `default` = Self(traits: .textGeneration)

    public var backend: ModelBackend?
    public var traits: ModelSelectionTraits
    public var spec: ModelSpecDescriptor?

    public init(
        backend: ModelBackend? = nil,
        traits: ModelSelectionTraits = [],
        spec: ModelSpecDescriptor? = nil
    ) {
        self.backend = backend
        self.traits = traits
        self.spec = spec
    }
}

public enum ModelBackend: Codable, Equatable, Hashable, Sendable {
    case mlx
    case custom(String)
}

public struct ModelSpecDescriptor: Codable, Equatable, Hashable, Sendable {
    /// Every constraint the descriptor carries, for printers: `id @ rev8 +file.json`, each part present
    /// only when set, `nil` when the descriptor pins nothing. Matching honours a revision or extra files
    /// without a source, so the printers show them too.
    public var pinDescription: String? {
        var parts: [String] = []
        if let sourceID { parts.append(sourceID) }
        if let revision { parts.append("@ \(revision.prefix(8))") }
        if !additionalFiles.isEmpty { parts.append("+" + additionalFiles.joined(separator: ",")) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public var sourceID: String?
    public var revision: String?
    public var additionalFiles: [String]

    public init(
        sourceID: String? = nil,
        revision: String? = nil,
        additionalFiles: [String] = []
    ) {
        self.sourceID = sourceID
        self.revision = revision
        self.additionalFiles = additionalFiles
    }
}
