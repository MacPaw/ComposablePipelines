//
//  DelegateReaderTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import DelegateAgent

/// Phase 3.5 — the read-only `DelegateReader` proxy exposes the reduced live delegate shape (active count,
/// tree, per-node lookup, children) to a body.
final class DelegateReaderTests: XCTestCase {

    private func snapshot() -> DelegateSnapshot {
        DelegateSnapshot.reduce(epoch: 2, [
            DelegateStatus(runID: .root.child(0), phase: .running),
            DelegateStatus(runID: .root.child(1), phase: .completed),
            DelegateStatus(runID: .root.child(0).child(0), phase: .running),
            DelegateStatus(runID: .root.child(0).child(1), phase: .refused),
        ])
    }

    func testProxyExposesReducedState() {
        let (epoch, active, count) = DelegateReader.read(snapshot()) { proxy in
            (proxy.epoch, proxy.activeCount, proxy.tree.count)
        }
        XCTAssertEqual(epoch, 2)
        XCTAssertEqual(active, 2, "root.0 and root.0.0 are running")
        XCTAssertEqual(count, 4)
    }

    func testProxyNavigatesChildren() {
        let children = DelegateReader.read(snapshot()) { proxy in
            proxy.children(of: .root.child(0)).map { $0.runID.description }
        }
        XCTAssertEqual(children, ["root.0.0", "root.0.1"], "only direct children of root.0")
    }

    func testProxyLooksUpByRunID() {
        let phase = DelegateReader.read(snapshot()) { $0.status(for: .root.child(1))?.phase }
        XCTAssertEqual(phase, .completed)
    }
}
