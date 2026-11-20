//
//  DelegateScopeTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL
import PipelineCompiler
import ExecutionEngine
import ComposablePipelines
import DelegateAgent

/// Phase 3.3 — ambient scope flows *down* into an isolated subagent run by being seeded into it
/// (`initialSlots`), the mechanism the 3.1 spike validated, and a child derives its own children's
/// scopes by extending the id while keeping the budget shape.
final class DelegateScopeTests: XCTestCase {

    private struct ScopeChild: Pipeline {
        typealias Output = DelegateScope
        @State var scope = DelegateScope(runID: .root, budgetTotal: 0)
        var body: some Pipeline { $scope.get() }
    }

    func testScopeInheritsIntoChildViaSeededSlot() async throws {
        let child = ScopeChild()
        let inherited = DelegateScope(runID: .root.child(2), budgetTotal: 32, budgetLeafReserve: 2)

        let lowered = child.lowered()
        let graph = PipelineCompiler().compile(lowered.graph)
        let out = try await PipelineWalker(executor: MockExecutor()).run(
            graph: graph,
            initialSlots: [child.$scope.id: try JSONEncoder().encode(inherited)]
        )

        XCTAssertEqual(try JSONDecoder().decode(DelegateScope.self, from: out), inherited,
                       "the subagent reads the ambient scope its parent seeded")
    }

    func testChildScopeExtendsIdKeepingBudget() {
        let parent = DelegateScope(runID: .root.child(1), budgetTotal: 16, budgetLeafReserve: 1)
        let grandchild = parent.child(3)
        XCTAssertEqual(grandchild.runID.description, "root.1.3")
        XCTAssertEqual(grandchild.budgetTotal, 16)
        XCTAssertEqual(grandchild.budgetLeafReserve, 1)
    }
}
