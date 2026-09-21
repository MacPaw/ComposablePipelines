//
//  Condition.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

/// Typical leaf predicate for control flow (`Pipeline` + ``Output`` is ``Bool``).
public protocol BooleanLeaf: LeafPipeline, BooleanPipeline where Output == Bool {}
