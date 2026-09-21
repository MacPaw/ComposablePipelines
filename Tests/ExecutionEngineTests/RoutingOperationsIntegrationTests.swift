//
//  RoutingOperationsIntegrationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
import PipelineDSL
@testable import ExecutionEngine

/// Integration tests for the routing seam: `Router`, `DAGPlanner`, and `RelevanceRanker` each
/// cross the full DSL → compiler → walker → executor dispatch path.
///
/// Two cases per operation:
/// - **noBackend fallback** – plain `ScriptedExecutor` does not override the routing methods so
///   the walker's built-in fallback fires (default route / empty DAG / passthrough ranking).
/// - **Happy path** – `RoutingScriptedExecutor` supplies canned results and the pipeline reads them.
final class RoutingOperationsIntegrationTests: XCTestCase {

    // MARK: - Pipeline fixtures

    private struct RouterPipeline: Pipeline {
        let query: String
        @State("route") var route = WorkflowRoute.default.rawValue
        var body: some Pipeline {
            $route.set { Router(query, tools: []) }
            $route.get()
        }
    }

    private struct DAGPlannerPipeline: Pipeline {
        let query: String
        @State("plan") var plan = DAGPlanningResult(text: nil, dag: nil)
        var body: some Pipeline {
            $plan.set { DAGPlanner(query, tools: []) }
            Just(value: plan.dag != nil ? "has-dag" : (plan.text ?? "no-dag"))
        }
    }

    private struct RelevanceRankerPipeline: Pipeline {
        let query: String
        let tools: [ToolDescriptor]
        @State("ranked") var ranked = RelevanceRankingResult(rankedTools: [])
        var body: some Pipeline {
            $ranked.set { RelevanceRanker(query, tools: tools) }
            Just(value: "")
        }
    }

    // MARK: - Routing executor

    /// Wraps `ScriptedExecutor` for model calls and overrides only the routing seam methods.
    private struct RoutingScriptedExecutor: Executor {
        let base: ScriptedExecutor
        let routerReply: WorkflowRoute?
        let dagReply: DAGPlanningResult?
        let rankReply: RelevanceRankingResult?

        func runModel(
            config: ModelConfig,
            arguments: ModelArguments,
            onDelta: (@Sendable (String) -> Void)?
        ) async throws -> ExecutionValue {
            try await base.runModel(config: config, arguments: arguments, onDelta: onDelta)
        }

        func runRouter(query: ExecutionValue, tools: [ToolDescriptor]) async throws -> ExecutionValue {
            guard let route = routerReply else { throw ExecutorError.noBackend }
            return try JSONEncoder().encode(route.rawValue)
        }

        func runDAGPlan(
            query: ExecutionValue,
            tools: [ToolDescriptor],
            hints: [String]
        ) async throws -> ExecutionValue {
            guard let plan = dagReply else { throw ExecutorError.noBackend }
            return try JSONEncoder().encode(plan)
        }

        func runRelevanceRank(
            query: ExecutionValue,
            tools: [ToolDescriptor],
            threshold: Float,
            topK: Int
        ) async throws -> ExecutionValue {
            guard let result = rankReply else { throw ExecutorError.noBackend }
            return try JSONEncoder().encode(result)
        }
    }

    // MARK: - Helpers

    private static let stub = ToolDescriptor(
        name: "ping",
        description: "Ping a host",
        inputSchema: .object(properties: ["hostname": .string], required: ["hostname"])
    )

    // MARK: - Router

    func testRouter_noBackend_fallsBackToDefaultRoute() async throws {
        let pipeline = RouterPipeline(query: "hello")
        let (result, _) = try await PipelineRun.runOnce(pipeline, executor: ScriptedExecutor.sequence([""]))
        let route = try JSONDecoder().decode(String.self, from: result)
        XCTAssertEqual(route, WorkflowRoute.default.rawValue)
    }

    func testRouter_happyPath_returnsScriptedRoute() async throws {
        let pipeline = RouterPipeline(query: "ping google.com")
        let executor = RoutingScriptedExecutor(
            base: ScriptedExecutor.sequence([""]),
            routerReply: .complexToolCall,
            dagReply: nil,
            rankReply: nil
        )
        let (result, _) = try await PipelineRun.runOnce(pipeline, executor: executor)
        let route = try JSONDecoder().decode(String.self, from: result)
        XCTAssertEqual(route, WorkflowRoute.complexToolCall.rawValue)
    }

    // MARK: - DAGPlanner

    func testDAGPlanner_noBackend_fallsBackToEmptyPlan() async throws {
        let pipeline = DAGPlannerPipeline(query: "flip then crop")
        let (result, _) = try await PipelineRun.runOnce(pipeline, executor: ScriptedExecutor.sequence([""]))
        let output = try JSONDecoder().decode(String.self, from: result)
        XCTAssertEqual(output, "no-dag")
    }

    func testDAGPlanner_happyPath_returnsScriptedDAG() async throws {
        let dag = TaskDAG(
            nodes: ["step1": TaskDAGNode(toolId: "flip_image", stepDescription: "Flip the image")],
            edges: []
        )
        let pipeline = DAGPlannerPipeline(query: "flip then crop")
        let executor = RoutingScriptedExecutor(
            base: ScriptedExecutor.sequence([""]),
            routerReply: nil,
            dagReply: DAGPlanningResult(text: nil, dag: dag),
            rankReply: nil
        )
        // runReactive so re-lowering picks up the committed plan and the Just branch re-evaluates.
        let (result, _) = try await PipelineRun.runReactive(pipeline, executor: executor)
        let output = try JSONDecoder().decode(String.self, from: result)
        XCTAssertEqual(output, "has-dag")
    }

    // MARK: - RelevanceRanker

    func testRelevanceRanker_noBackend_passthroughAllToolsAtFullScore() async throws {
        let tools = (0..<4).map { i in
            ToolDescriptor(name: "tool\(i)", description: "Tool \(i)", inputSchema: .any)
        }
        let pipeline = RelevanceRankerPipeline(query: "test", tools: tools)
        let (_, events) = try await PipelineRun.runOnce(pipeline, executor: ScriptedExecutor.sequence([""]))
        let ranked = try JSONDecoder().decode(
            RelevanceRankingResult.self,
            from: XCTUnwrap(events.slotHistory(pipeline.$ranked.id).last)
        )
        XCTAssertEqual(ranked.rankedTools.count, 4)
        XCTAssertTrue(ranked.rankedTools.allSatisfy { $0.score == 1.0 })
    }

    func testRelevanceRanker_happyPath_returnsScriptedRanking() async throws {
        let tools = [Self.stub]
        let scripted = RelevanceRankingResult(rankedTools: [RankedTool(descriptor: Self.stub, score: 0.92)])
        let pipeline = RelevanceRankerPipeline(query: "is google.com up?", tools: tools)
        let executor = RoutingScriptedExecutor(
            base: ScriptedExecutor.sequence([""]),
            routerReply: nil,
            dagReply: nil,
            rankReply: scripted
        )
        let (_, events) = try await PipelineRun.runOnce(pipeline, executor: executor)
        let ranked = try JSONDecoder().decode(
            RelevanceRankingResult.self,
            from: XCTUnwrap(events.slotHistory(pipeline.$ranked.id).last)
        )
        XCTAssertEqual(ranked.rankedTools.count, 1)
        XCTAssertEqual(ranked.rankedTools[0].descriptor.name, "ping")
        XCTAssertEqual(ranked.rankedTools[0].score, 0.92, accuracy: 0.001)
    }
}
