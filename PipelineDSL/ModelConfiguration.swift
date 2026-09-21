//
//  ModelConfiguration.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Identity of the in-process model to invoke via ``ResourceHeap/modelProvider``.
public struct ModelConfiguration: Sendable, Hashable {
    public let modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }

    public static func engine(modelID: String) -> ModelConfiguration {
        ModelConfiguration(modelID: modelID)
    }
}
