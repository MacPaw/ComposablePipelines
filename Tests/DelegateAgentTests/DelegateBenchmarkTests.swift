//
//  DelegateBenchmarkTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import DelegateAgent

/// Phase 6.1 — the comparison harness runs, over a fixed noisy task set, and the delegate (flood +
/// aggregation) is measurably more accurate than a single attempt. Prints the metrics so the baseline
/// findings (6.2) can be recorded.
final class DelegateBenchmarkTests: XCTestCase {

    /// 20 tasks. Worker 0 (the single-attempt baseline) is wrong on the even-indexed tasks; every
    /// other worker is always right — so the delegate's majority recovers the correct answer everywhere.
    private func noisyTasks() -> [DelegateBenchmark.Task<String>] {
        (0..<20).map { t in
            DelegateBenchmark.Task(prompt: "task \(t)", correct: "ans\(t)") { workerIndex in
                if workerIndex == 0 && t % 2 == 0 { return "wrong\(t)" }
                return "ans\(t)"
            }
        }
    }

    func testDelegateBeatsSingleAttemptOnNoisySet() {
        let tasks = noisyTasks()
        let delegate = DelegateBenchmark.delegate(tasks, delegateSize: 5)
        let single = DelegateBenchmark.singleAttempt(tasks)

        print("""
            [delegate-benchmark] noisy set: \(tasks.count) tasks
              single : accuracy=\(single.accuracy)  calls=\(single.modelCalls)  usefulPerCall=\(single.usefulPerCall)
              delegate  : accuracy=\(delegate.accuracy)  calls=\(delegate.modelCalls)  usefulPerCall=\(delegate.usefulPerCall)
            """)

        XCTAssertEqual(single.accuracy, 0.5, accuracy: 0.001, "the single worker is wrong on half the tasks")
        XCTAssertEqual(delegate.accuracy, 1.0, accuracy: 0.001, "the delegate's majority recovers every answer")
        XCTAssertGreaterThan(delegate.accuracy, single.accuracy, "the delegate is more accurate")
        XCTAssertEqual(delegate.modelCalls, 100, "5 workers × 20 tasks")
        XCTAssertGreaterThan(delegate.usefulPerCall, 0, "the delegate produces useful work")
    }
}
