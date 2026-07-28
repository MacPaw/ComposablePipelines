//
//  Pipeline+Assign.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

extension Pipeline {
    /// Producer-first spelling of ``Binding/set(writeKind:_:)`` — writes this pipeline's
    /// output into the slot:
    ///
    /// ```swift
    /// Run($draft) { $0.count }
    ///     .assign(to: $wordCount)
    /// ```
    ///
    /// Reads like Combine's `assign(to:)` and avoids the extra nesting level of
    /// `$wordCount.set { … }`.
    ///
    /// **Dependency capture.** This is the producer-first spelling of the *value* form
    /// `$slot.set(producer)`, so the producer's dependencies must be **graph-encoded**:
    /// `.input { $slot }`, ``Run``, ``Binding/map(_:)``, constants, or plain `let`s. A postfix
    /// modifier cannot capture bare-`@State` reads made *while building* the producer (e.g.
    /// `Model("…").message(keyPoints)` or a prompt interpolating `\(severity)`) — for those,
    /// use the closure form `$slot.set { producer }`, which snapshots reads before building.
    public func assign(
        to binding: Binding<Output>,
        writeKind: StateWriteKind = .commit
    ) -> Binding<Output>.SetValue<Self> where Output: Hashable & Sendable & Codable {
        binding.set(self, writeKind: writeKind)
    }
}
