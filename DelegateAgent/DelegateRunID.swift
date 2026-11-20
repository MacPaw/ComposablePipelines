//
//  DelegateRunID.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// A subagent's identity, derived from its **position in the delegate tree** rather than a random UUID.
///
/// The root delegate is `root`; its i-th child is `root.i`; that child's j-th child is `root.i.j`, and so
/// on. This path *is* the coordinate space the observation layer keys on — the per-epoch status reduce
/// (Phase 3.4) folds siblings and the reader/proxy addresses nodes by their path. Position-based ids
/// are stable across re-execution (unlike freshly-minted UUIDs), which is what lets a reduce over a
/// changing membership set stay consistent.
///
/// - Author: Claude
public struct DelegateRunID: Codable, Sendable, Hashable, CustomStringConvertible {

    /// Child indices from the root down. Empty is the root itself.
    public let path: [Int]

    public init(path: [Int] = []) {
        self.path = path
    }

    /// The root of a delegate tree.
    public static let root = DelegateRunID()

    /// The id of this node's `index`-th child.
    public func child(_ index: Int) -> DelegateRunID {
        DelegateRunID(path: path + [index])
    }

    /// This node's parent, or `nil` at the root.
    public var parent: DelegateRunID? {
        path.isEmpty ? nil : DelegateRunID(path: Array(path.dropLast()))
    }

    /// Depth in the tree; the root is `0`.
    public var depth: Int { path.count }

    /// `root`, `root.0`, `root.0.2.1`, …
    public var description: String {
        path.isEmpty ? "root" : "root." + path.map(String.init).joined(separator: ".")
    }

    /// Parse the `root[.i.j…]` form produced by ``description``. Returns `nil` for malformed input.
    public init?(_ string: String) {
        guard string == "root" || string.hasPrefix("root.") else { return nil }
        if string == "root" {
            self.path = []
            return
        }
        let tail = string.dropFirst("root.".count)
        var indices: [Int] = []
        for component in tail.split(separator: ".", omittingEmptySubsequences: false) {
            guard let index = Int(component), index >= 0 else { return nil }
            indices.append(index)
        }
        self.path = indices
    }
}
