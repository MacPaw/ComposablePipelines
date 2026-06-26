//
//  ContextItem.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// One piece of augmented context produced by a provider and consumed by a
/// pipeline (typically to enrich an LLM prompt).
///
/// Three fields:
///   - `kind`   : what is this thing? (`file`, `memo`, `slack_message`, …)
///   - `source` : where did it come from? (`mnemos`, `long_term_memory`, …)
///   - `value`  : kind-specific data, as a self-describing JSON value.
///
/// Both `kind` and `source` are open enums — the toolchain ships no
/// built-in values. Clients define their own via extension on
/// ``ContextItemKind`` and ``ContextSourceID``.
public struct ContextItem: Hashable, Codable, Sendable {
    public let kind: ContextItemKind
    public let source: ContextSourceID
    public let value: JSONValue

    public init(
        kind: ContextItemKind,
        source: ContextSourceID,
        value: JSONValue
    ) {
        self.kind = kind
        self.source = source
        self.value = value
    }
}
