//
//  StateUpdate.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// A single slot write produced during pipeline execution.
///
/// `StateUpdate` values are accumulated while a `.parallel` group is running and
/// flushed as a batch once all branches complete — giving the observer one
/// consolidated snapshot per parallel group rather than one per slot write.
public struct StateUpdate: Sendable {
    public let slotID: UUID
    public let valueTypeName: String
    public let debugLabel: String?
    /// The slot value immediately before this write, or `nil` if the slot was empty.
    public let previousValue: ExecutionValue?
    public let value: ExecutionValue
    public let epoch: ExecutionEpoch
    public let kind: StateWriteKind

    public init(
        slotID: UUID,
        valueTypeName: String,
        debugLabel: String?,
        previousValue: ExecutionValue?,
        value: ExecutionValue,
        epoch: ExecutionEpoch,
        kind: StateWriteKind = .commit
    ) {
        self.slotID = slotID
        self.valueTypeName = valueTypeName
        self.debugLabel = debugLabel
        self.previousValue = previousValue
        self.value = value
        self.epoch = epoch
        self.kind = kind
    }
}
