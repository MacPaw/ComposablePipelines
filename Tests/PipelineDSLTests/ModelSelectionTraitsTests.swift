//
//  ModelSelectionTraitsTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST

/// `ModelSelectionTraits` is an IPC-stable bit layout: it rides inside a serialized `PipelineGraph` as a
/// bare `UInt32`, so a client and an agent only agree on what a request means while the bit *positions*
/// match. Adding a bit is safe; renumbering one silently re-points every existing payload at a different
/// capability.
///
/// Nothing enforced that before this file — the guarantee lived only in a doc comment. These tests pin the
/// wire values so a reorder fails here instead of in the field.
final class ModelSelectionTraitsTests: XCTestCase {

    private struct Pin {
        let name: String
        let trait: ModelSelectionTraits
        let rawValue: UInt32

        init(_ name: String, _ trait: ModelSelectionTraits, _ rawValue: UInt32) {
            self.name = name
            self.trait = trait
            self.rawValue = rawValue
        }
    }

    /// Every trait's wire value, spelled out. Update this only when *adding* a trait.
    private static let pinned: [Pin] = [
        Pin("quick", .quick, 1 << 0),
        Pin("localOnly", .localOnly, 1 << 1),
        Pin("instruct", .instruct, 1 << 2),
        Pin("reasoning", .reasoning, 1 << 3),
        Pin("streaming", .streaming, 1 << 4),
        Pin("lowMemory", .lowMemory, 1 << 5),
        Pin("lowCost", .lowCost, 1 << 6),
        Pin("chatCompletion", .chatCompletion, 1 << 7),
        Pin("textGeneration", .textGeneration, 1 << 8),
        Pin("summarize", .summarize, 1 << 9),
        Pin("textClassification", .textClassification, 1 << 10),
        Pin("embeddingsGeneration", .embeddingsGeneration, 1 << 11),
        Pin("taskPlanning", .taskPlanning, 1 << 12),
        Pin("memoryExtraction", .memoryExtraction, 1 << 13),
        Pin("entityExtraction", .entityExtraction, 1 << 14),
        Pin("memoryNormalization", .memoryNormalization, 1 << 15),
    ]

    func testWireValuesAreStable() {
        for pin in Self.pinned {
            XCTAssertEqual(pin.trait.rawValue, pin.rawValue,
                           "\(pin.name) moved — that repoints existing IPC payloads")
        }
    }

    func testNoTwoTraitsShareABit() {
        var seen: [UInt32: String] = [:]
        for pin in Self.pinned {
            if let clash = seen[pin.rawValue] {
                XCTFail("\(pin.name) and \(clash) both claim bit \(pin.rawValue)")
            }
            seen[pin.rawValue] = pin.name
        }
    }

    /// Bits that once carried a trait and were retired. Never reused, so never pinned to a name.
    static let retiredBits: UInt32 = 1 << 16 | 1 << 17   // guardrailClassification (IPC v18), promptClassification (IPC v18)

    func testEveryTraitIsPinned() {
        // A trait added without a pin here would slip past the layout guarantee entirely.
        let union = Self.pinned.reduce(into: ModelSelectionTraits()) { $0.formUnion($1.trait) }
        let width = Self.pinned.count + Self.retiredBits.nonzeroBitCount
        XCTAssertEqual(union.rawValue | Self.retiredBits, (1 << width) - 1,
                       "traits must occupy a contiguous bit range with every live bit pinned above")
        XCTAssertEqual(union.rawValue & Self.retiredBits, 0, "a retired bit must not be reassigned")
    }

    func testTraitsEncodeAsABareNumber() throws {
        // The synthesized OptionSet Codable emits the raw value, not a keyed object. A hand-written
        // Codable here would change the wire format for every graph in flight.
        let data = try JSONEncoder().encode(ModelSelectionTraits([.chatCompletion, .quick]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\((1 << 7 | 1 << 0) as UInt32)")
    }

    func testOlderPayloadsKeepTheirMeaning() throws {
        // A graph serialized before the retired bits existed must still mean exactly what it meant.
        let legacy = try JSONDecoder().decode(
            ModelSelectionTraits.self, from: Data("\(1 << 7 | 1 << 10)".utf8))
        XCTAssertEqual(legacy, [.chatCompletion, .textClassification])
    }

    func testRetiredBitsAreNeitherNamedNorReused() {
        // Bit 16 carried `guardrailClassification` and bit 17 `promptClassification` until IPC v18. A
        // payload from an older peer may still set them; each must decode as an unnamed flag
        // and match no current trait.
        for bit: UInt32 in [1 << 16, 1 << 17] {
            let retired = ModelSelectionTraits(rawValue: bit)
            for pin in Self.pinned {
                XCTAssertFalse(retired.contains(pin.trait), "\(pin.name) must not sit on retired bit \(bit)")
            }
        }
    }
}
