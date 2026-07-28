//
//  RoutingPipelineTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL

final class RoutingPipelineTests: XCTestCase {
    func testRouterLowersToRouterLeaf() {
        let graph = Router("Find the release notes").pipelineGraph

        guard case let .leaf(.router(query, _)) = graph else {
            XCTFail("expected router leaf")
            return
        }

        guard case let .leaf(.just(valueTypeName, jsonUTF8)) = query else {
            XCTFail("expected constant router query")
            return
        }
        XCTAssertEqual(valueTypeName, "String")
        XCTAssertEqual(jsonUTF8, "\"Find the release notes\"")
    }

    func testDAGPlannerLowersToDAGPlanLeafWithToolsAndHints() {
        let tool = ToolDescriptor(
            name: "search_demo_knowledge",
            description: "Searches demo knowledge.",
            inputSchema: .object(properties: ["query": .string], required: ["query"])
        )

        let graph = DAGPlanner(
            "Find and summarize release notes",
            tools: [tool],
            hints: ["Prefer a small DAG."]
        )
        .pipelineGraph

        guard case let .leaf(.dagPlan(query, tools, hints)) = graph else {
            XCTFail("expected dagPlan leaf")
            return
        }
        XCTAssertEqual(tools, [tool])
        XCTAssertEqual(hints, ["Prefer a small DAG."])

        guard case let .leaf(.just(valueTypeName, jsonUTF8)) = query else {
            XCTFail("expected constant DAG query")
            return
        }
        XCTAssertEqual(valueTypeName, "String")
        XCTAssertEqual(jsonUTF8, "\"Find and summarize release notes\"")
    }
}
