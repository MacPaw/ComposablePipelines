//
//  Array+ContextItem.swift
//  elix-toolchain
//
//  Created on 12.05.2026.
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
