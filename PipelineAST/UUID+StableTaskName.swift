//
//  UUID+StableTaskName.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

extension UUID {
    /// Deterministic UUID for a stable, human-readable task name.
    ///
    /// Graphs that cross the wire dispatch client actions by `taskID` alone — closures never
    /// leave the authoring process. Deriving the UUID from a fixed name lets both sides agree
    /// on the identity across lowerings, launches, and processes:
    ///
    /// ```swift
    /// Run(id: "word-count", $draft) { … }              // authoring side
    /// UUID(stableTaskName: "word-count")               // dispatching side
    /// ```
    ///
    /// Two independent FNV-1a 64-bit lanes (forward and reversed byte order, distinct seeds)
    /// fill the 16 bytes; version (8, custom) and RFC 4122 variant bits are stamped so the
    /// result is a well-formed UUID. Not cryptographic — collision resistance is scaled to
    /// task naming within one product, not adversarial input.
    public init(stableTaskName name: String) {
        func fnv1a(_ bytes: some Sequence<UInt8>, seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }

        let utf8 = Array(name.utf8)
        let lanes = [
            fnv1a(utf8, seed: 0xCBF2_9CE4_8422_2325),
            fnv1a(utf8.reversed(), seed: 0x6C62_272E_07BB_0142),
        ]

        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for lane in lanes {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: lane >> UInt64(shift)))
            }
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x80  // version 8 (custom)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant

        self.init(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
