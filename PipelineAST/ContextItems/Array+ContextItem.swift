//
//  Array+ContextItem.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

public extension Array where Element == ContextItem {

    /// Remove items equal under `Hashable`. The first occurrence is kept;
    /// subsequent duplicates are dropped.
    func dedup() -> [ContextItem] {
        var seen: Set<ContextItem> = []
        return filter { seen.insert($0).inserted }
    }

    /// Keep only items whose ``ContextItem/kind`` matches `kind`.
    func of(kind: ContextItemKind) -> [ContextItem] {
        filter { $0.kind == kind }
    }

    /// Keep only items whose ``ContextItem/source`` matches `source`.
    func from(source: ContextSourceID) -> [ContextItem] {
        filter { $0.source == source }
    }
}
