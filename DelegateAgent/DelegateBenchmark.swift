//
//  DelegateBenchmark.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation

/// Metrics for one approach over a fixed task set. `usefulPerCall` is the CI-runnable proxy for the
/// real bet metric — **useful tokens per model-second**: correct answers that survive aggregation per
/// unit of model work (here, per model call, since a scripted backend has no meaningful wall-clock).
public struct DelegateBenchmarkMetrics: Sendable, Hashable {
    public let approach: String
    public let taskCount: Int
    public let correct: Int
    public let modelCalls: Int

    public init(approach: String, taskCount: Int, correct: Int, modelCalls: Int) {
        self.approach = approach
        self.taskCount = taskCount
        self.correct = correct
        self.modelCalls = modelCalls
    }

    /// Fraction of tasks answered correctly.
    public var accuracy: Double { taskCount == 0 ? 0 : Double(correct) / Double(taskCount) }
    /// Correct answers per model call — the duty-cycle proxy (a busy model producing discarded work
    /// scores low, exactly as the bet demands).
    public var usefulPerCall: Double { modelCalls == 0 ? 0 : Double(correct) / Double(modelCalls) }
}

/// A side-by-side comparison harness: the same task set solved by a **delegate** (breadth-first flood +
/// aggregation) versus a **single attempt** (the baseline the delegate must beat), measuring accuracy and
/// model-work.
///
/// This is the CI-runnable core of the bet — delegate vs one attempt. The full delegate-vs-legacy
/// (`Router` / `DAGPlanner` / `RelevanceRanker`) comparison keeps the legacy blocks untouched and
/// *uses* them, but requires the real agent + `LiquidAI/LFM2.5` to produce meaningful wall-clock and
/// token counts; see `DelegateAgent.md` for how to run it against local hardware.
///
/// - Author: Claude
public enum DelegateBenchmark {

    /// One task: a prompt, its known-correct answer, and a noisy worker model.
    public struct Task<Answer: Equatable & Sendable>: Sendable {
        public let prompt: String
        public let correct: Answer
        /// The i-th worker's answer for this task — noisy by construction so the comparison is honest.
        public let worker: @Sendable (_ workerIndex: Int) -> Answer

        public init(prompt: String, correct: Answer, worker: @escaping @Sendable (Int) -> Answer) {
            self.prompt = prompt
            self.correct = correct
            self.worker = worker
        }
    }

    /// Run the delegate approach: `delegateSize` workers per task, aggregated by majority quorum.
    public static func delegate<Answer: Hashable & Sendable>(
        _ tasks: [Task<Answer>],
        delegateSize: Int
    ) -> DelegateBenchmarkMetrics {
        var correct = 0
        var calls = 0
        for task in tasks {
            let answers = (0..<delegateSize).map { task.worker($0) }
            calls += delegateSize
            let results = answers.enumerated().map {
                DelegateResult(id: "\($0.offset)", answer: "\($0.element)", confidence: 1.0)
            }
            let winner = DelegateAggregator.aggregate(results, policy: .quorum(delegateSize / 2 + 1)).winner
            if winner?.answer == "\(task.correct)" { correct += 1 }
        }
        return DelegateBenchmarkMetrics(approach: "delegate(\(delegateSize))", taskCount: tasks.count, correct: correct, modelCalls: calls)
    }

    /// Run the single-attempt baseline: one worker (index 0) per task.
    public static func singleAttempt<Answer: Hashable & Sendable>(
        _ tasks: [Task<Answer>]
    ) -> DelegateBenchmarkMetrics {
        var correct = 0
        for task in tasks where task.worker(0) == task.correct { correct += 1 }
        return DelegateBenchmarkMetrics(approach: "single", taskCount: tasks.count, correct: correct, modelCalls: tasks.count)
    }
}
