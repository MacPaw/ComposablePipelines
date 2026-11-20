//
//  PipelineLoweringGuard.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Cycle guard for pipeline lowering. Tracks which pipeline **types** are currently being lowered to
/// a graph on the lowering call stack.
///
/// It exists so a self-referential `Delegate(prototype:)` terminates: a prototype whose type is already
/// being lowered is recognized as **self-recursion** and lowered to ``DelegateChild/selfRecursion``
/// instead of embedding it — embedding would recurse forever, because the prototype's own body
/// contains the very same delegate. Building the prototype is deferred to lowering (not construction)
/// precisely so this guard can fire before the cycle is entered.
///
/// - Author: Claude
public enum PipelineLoweringGuard {
    @TaskLocal private static var typesInProgress: Set<ObjectIdentifier> = []

    /// True if `type` is already being lowered further up the current lowering call stack.
    public static func isLowering<P>(_ type: P.Type) -> Bool {
        typesInProgress.contains(ObjectIdentifier(type))
    }

    /// Evaluate `body` with `type` marked in-progress, so a nested lowering of the same type detects
    /// the cycle via ``isLowering(_:)``.
    public static func lowering<P>(_ type: P.Type, _ body: () -> PipelineGraph) -> PipelineGraph {
        $typesInProgress.withValue(typesInProgress.union([ObjectIdentifier(type)]), operation: body)
    }
}
