//
//  ExecutionEpoch.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Monotonic counter: increments once per committed execution-slot write (lockstep server/client).
public typealias ExecutionEpoch = UInt64
