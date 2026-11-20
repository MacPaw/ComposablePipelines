//
//  DelegateDecorrelationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import DelegateAgent

/// Phase 4.3 — worker variation so ensemble errors decorrelate.
final class DelegateDecorrelationTests: XCTestCase {

    func testTemperatureRampsUpwardAcrossSiblings() {
        let count = 5
        let temps = (0..<count).map {
            DelegateDecorrelation.sampling(forSibling: $0, of: count, maxTemperature: 0.9).temperature
        }
        XCTAssertEqual(temps[0], DelegateModelConfig.Sampling.worker.temperature, accuracy: 0.0001,
                       "sibling 0 keeps the reliable base temperature")
        XCTAssertEqual(temps.last!, 0.9, accuracy: 0.0001, "the last sibling reaches max temperature")
        for i in 1..<count {
            XCTAssertGreaterThan(temps[i], temps[i - 1], "temperature increases monotonically")
        }
    }

    func testSingleWorkerKeepsBaseSampling() {
        let sampling = DelegateDecorrelation.sampling(forSibling: 0, of: 1)
        XCTAssertEqual(sampling, .worker, "a lone worker gets the base sampling, no ramp")
    }

    func testSamplingCarriesTopPAndPenalty() {
        let sampling = DelegateDecorrelation.sampling(forSibling: 2, of: 4)
        XCTAssertEqual(sampling.topP, DelegateModelConfig.Sampling.worker.topP)
        XCTAssertEqual(sampling.repetitionPenalty, DelegateModelConfig.Sampling.worker.repetitionPenalty)
    }

    func testFramingsCycleAndAreDistinct() {
        XCTAssertEqual(DelegateDecorrelation.framing(forSibling: 0), DelegateDecorrelation.framings[0])
        XCTAssertEqual(
            DelegateDecorrelation.framing(forSibling: DelegateDecorrelation.framings.count),
            DelegateDecorrelation.framings[0],
            "framings cycle"
        )
        XCTAssertEqual(Set(DelegateDecorrelation.framings).count, DelegateDecorrelation.framings.count,
                       "framings are distinct")
    }
}
