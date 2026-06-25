//
//  ModelSelectionRequirements.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

public struct ModelSelectionRequirements: Codable, Equatable, Sendable {
    public static let `default` = Self(purpose: .textGeneration)

    public var purpose: ModelPurpose?
    public var backend: ModelBackend?
    public var traits: ModelSelectionTraits
    public var spec: ModelSpecDescriptor?

    public init(
        purpose: ModelPurpose? = nil,
        backend: ModelBackend? = nil,
        traits: ModelSelectionTraits = [],
        spec: ModelSpecDescriptor? = nil
    ) {
        self.purpose = purpose
        self.backend = backend
        self.traits = traits
        self.spec = spec
    }
}

public enum ModelPurpose: String, Codable, Equatable, Sendable {
    case chatCompletion
    case textGeneration
    case summarize
    case textClassification
    case embeddingsGeneration
    case taskPlanning
}

public enum ModelBackend: Codable, Equatable, Sendable {
    case mlx
    case custom(String)
}

public struct ModelSpecDescriptor: Codable, Equatable, Sendable {
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
