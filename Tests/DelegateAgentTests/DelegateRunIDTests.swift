//
//  DelegateRunIDTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import DelegateAgent

/// Phase 3.2 — hierarchical, position-based run identity: the coordinate space the observation layer
/// keys on.
final class DelegateRunIDTests: XCTestCase {

    func testChildAndParentNavigation() {
        let node = DelegateRunID.root.child(0).child(2).child(1)
        XCTAssertEqual(node.description, "root.0.2.1")
        XCTAssertEqual(node.depth, 3)
        XCTAssertEqual(node.parent, DelegateRunID.root.child(0).child(2))
        XCTAssertNil(DelegateRunID.root.parent)
        XCTAssertEqual(DelegateRunID.root.description, "root")
        XCTAssertEqual(DelegateRunID.root.depth, 0)
    }

    func testStringRoundTrip() {
        for node in [DelegateRunID.root, .root.child(3), .root.child(0).child(11).child(4)] {
            XCTAssertEqual(DelegateRunID(node.description), node)
        }
    }

    func testParsingRejectsMalformedInput() {
        XCTAssertNil(DelegateRunID("nope"))
        XCTAssertNil(DelegateRunID("root.a"))
        XCTAssertNil(DelegateRunID("root.-1"))
        XCTAssertNil(DelegateRunID(""))
    }

    func testCodableRoundTrip() throws {
        let node = DelegateRunID.root.child(1).child(9)
        let data = try JSONEncoder().encode(node)
        XCTAssertEqual(try JSONDecoder().decode(DelegateRunID.self, from: data), node)
    }

    func testHashableKeyingBySibling() {
        // Distinct siblings are distinct keys; equal paths collapse to one key.
        let keys: Set<DelegateRunID> = [.root.child(0), .root.child(1), .root.child(0)]
        XCTAssertEqual(keys.count, 2)
    }
}
