//
//  ContextItemsProvider.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Contract for any source of ``ContextItem``s.
///
/// Conformers are written by clients (long-term memory, a Slack integration,
/// a hardcoded fixture for tests, …). The toolchain ships none.
///
/// A provider is plugged into a pipeline via the `From(provider:)` DSL
/// operator; the engine calls ``fetch(query:)`` when the operator runs.
public protocol ContextItemsProvider: Sendable {

    /// The source identifier stamped onto every ``ContextItem`` this
    /// provider produces.
    var sourceID: ContextSourceID { get }

    /// Produce items relevant to `query`.
    func fetch(query: String) async throws -> [ContextItem]
}
