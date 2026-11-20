//
//  ExecutionCursor.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Executor → client re-execution cursor.
///
/// - `epoch`: last committed state-update epoch in the batch that triggered re-execution.
/// - `offset`: prefix-skip cursor in **surface-task ordinals** (same unit as the engine’s
///   offset-only prefix skip).
public struct ExecutionCursor: Codable, Equatable, Sendable {
    public let epoch: ExecutionEpoch
    public let offset: Int

    public init(epoch: ExecutionEpoch, offset: Int) {
        self.epoch = epoch
        self.offset = offset
    }
}

