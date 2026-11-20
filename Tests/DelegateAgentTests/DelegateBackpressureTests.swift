//
//  DelegateBackpressureTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import DelegateAgent

/// Phase 3.6 — backpressure/resource signals fold into the snapshot and surface through the proxy.
final class DelegateBackpressureTests: XCTestCase {

    func testReduceCarriesBackpressureToProxy() {
        let snapshot = DelegateSnapshot.reduce(
            epoch: 4,
            [DelegateStatus(runID: .root.child(0), phase: .running)],
            backpressure: DelegateBackpressure(budgetRemaining: 9, queueDepth: 3, kvHeadroom: 0.42)
        )

        DelegateReader.read(snapshot) { proxy in
            XCTAssertEqual(proxy.budgetRemaining, 9)
            XCTAssertEqual(proxy.backpressure.queueDepth, 3)
            XCTAssertEqual(proxy.backpressure.kvHeadroom, 0.42)
            XCTAssertEqual(proxy.activeCount, 1)
        }
    }

    func testUnknownSignalsAreNil() {
        let snapshot = DelegateSnapshot.reduce(epoch: 0, [], backpressure: DelegateBackpressure(budgetRemaining: 5))
        XCTAssertNil(snapshot.backpressure.queueDepth, "queue depth is nil when the inference layer hides it")
        XCTAssertNil(snapshot.backpressure.kvHeadroom)
        XCTAssertEqual(snapshot.backpressure.budgetRemaining, 5)
    }

    func testSinkAttachesBackpressure() async {
        let sink = DelegateStatusSink()
        await sink.publish(DelegateStatus(runID: .root.child(0), phase: .running))
        let snapshot = await sink.snapshot(epoch: 1, backpressure: DelegateBackpressure(budgetRemaining: 2))
        XCTAssertEqual(snapshot.backpressure.budgetRemaining, 2)
    }

    func testSnapshotWithBackpressureRoundTrips() throws {
        let snapshot = DelegateSnapshot.reduce(
            epoch: 7, [], backpressure: DelegateBackpressure(budgetRemaining: 1, queueDepth: 0, kvHeadroom: 1.0))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(DelegateSnapshot.self, from: data), snapshot)
    }
}
