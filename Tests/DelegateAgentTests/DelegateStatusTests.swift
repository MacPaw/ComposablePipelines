//
//  DelegateStatusTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import DelegateAgent

/// Phase 3.4 — the per-epoch status reduce: sibling statuses fold into one consistent snapshot
/// (last-per-id wins, ordered by tree position), and the sink accumulates + folds on demand.
final class DelegateStatusTests: XCTestCase {

    func testReduceDedupsByRunIDLastWinsAndOrders() {
        let raw = [
            DelegateStatus(runID: .root.child(1), phase: .running),
            DelegateStatus(runID: .root.child(0), phase: .running),
            DelegateStatus(runID: .root.child(1), phase: .completed, cost: 42),  // overwrites the earlier root.1
        ]
        let snapshot = DelegateSnapshot.reduce(epoch: 3, raw)

        XCTAssertEqual(snapshot.epoch, 3)
        XCTAssertEqual(snapshot.statuses.map { $0.runID.description }, ["root.0", "root.1"],
                       "one status per subagent, ordered by tree position")
        XCTAssertEqual(snapshot.status(for: .root.child(1))?.phase, .completed, "last write per id wins")
        XCTAssertEqual(snapshot.status(for: .root.child(1))?.cost, 42)
    }

    func testActiveCountCountsRunning() {
        let snapshot = DelegateSnapshot.reduce(epoch: 0, [
            DelegateStatus(runID: .root.child(0), phase: .running),
            DelegateStatus(runID: .root.child(1), phase: .running),
            DelegateStatus(runID: .root.child(2), phase: .completed),
            DelegateStatus(runID: .root.child(3), phase: .refused),
        ])
        XCTAssertEqual(snapshot.activeCount, 2)
    }

    func testSinkAccumulatesAndFoldsPerEpoch() async {
        let sink = DelegateStatusSink()
        await sink.publish(DelegateStatus(runID: .root.child(0), phase: .running))
        await sink.publish(DelegateStatus(runID: .root.child(1), phase: .running))
        // Overwrite child 0 as it completes.
        await sink.publish(DelegateStatus(runID: .root.child(0), phase: .completed, cost: 7))

        let snapshot = await sink.snapshot(epoch: 5)
        XCTAssertEqual(snapshot.epoch, 5)
        XCTAssertEqual(snapshot.statuses.count, 2)
        XCTAssertEqual(snapshot.status(for: .root.child(0))?.phase, .completed)
        XCTAssertEqual(snapshot.status(for: .root.child(0))?.cost, 7)
        XCTAssertEqual(snapshot.activeCount, 1)
    }

    func testSnapshotRoundTrips() throws {
        let snapshot = DelegateSnapshot.reduce(epoch: 1, [
            DelegateStatus(runID: .root.child(0).child(2), phase: .failed, cost: 3),
        ])
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(DelegateSnapshot.self, from: data), snapshot)
    }
}
