//
//  DelegateDSLTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
@testable import PipelineDSL

/// Step B — the `Delegate` DSL block lowers to a `.delegate` leaf carrying the child template, the task /
/// task-input slot ids, and the budget.
final class DelegateDSLTests: XCTestCase {

    private struct DelegatePipeline: Pipeline {
        typealias Output = [String?]
        @State var questions: [String] = ["a", "b"]
        @State var question: String = ""

        var body: some Pipeline {
            Delegate(tasks: $questions, taskInput: $question, budget: .init(total: 8, leafReserve: 1)) {
                Model<String>().input { $question.get() }
            }
        }
    }

    private struct InheritingDelegatePipeline: Pipeline {
        typealias Output = [String?]
        @State var questions: [String] = ["a", "b"]
        @State var question: String = ""

        var body: some Pipeline {
            Delegate(tasks: $questions, taskInput: $question, budget: .init(total: 8, leafReserve: 1),
                  inherit: [.tools, .memory]) {
                Model<String>().input { $question.get() }
            }
        }
    }

    func testDelegateLowersToDelegateLeaf() throws {
        let pipeline = DelegatePipeline()
        let graph = pipeline.loweredGraph()

        guard let leaf = firstDelegateLeaf(in: graph) else {
            return XCTFail("expected a .delegate leaf in the lowered graph")
        }

        guard case let .delegate(child, tasksSlotID, taskInputSlotID, budgetTotal, leafReserve, inherit) = leaf else {
            return XCTFail("unexpected leaf: \(leaf)")
        }

        XCTAssertEqual(tasksSlotID, pipeline.$questions.id, "tasks slot id must be the questions slot")
        XCTAssertEqual(taskInputSlotID, pipeline.$question.id, "task-input slot id must be the question slot")
        XCTAssertEqual(budgetTotal, 8)
        XCTAssertEqual(leafReserve, 1)
        XCTAssertEqual(inherit, .isolated, "a delegate inherits nothing unless the author opts in")
        guard case let .embedded(childGraph) = child else {
            return XCTFail("an inline Delegate { … } must lower to an embedded child, not self-recursion")
        }
        XCTAssertNotEqual(childGraph, .empty, "the child template must be embedded")
    }

    func testDelegateCarriesInheritanceMask() throws {
        let graph = InheritingDelegatePipeline().loweredGraph()

        guard let leaf = firstDelegateLeaf(in: graph),
              case let .delegate(_, _, _, _, _, inherit) = leaf else {
            return XCTFail("expected a .delegate leaf carrying an inheritance mask")
        }

        XCTAssertEqual(inherit, [.tools, .memory], "the DSL's inherit mask must reach the lowered leaf")
        XCTAssertFalse(inherit.contains(.context), "context was not granted and must not leak through")
    }

    private func firstDelegateLeaf(in graph: PipelineGraph) -> PipelineGraphLeaf? {
        switch graph {
        case let .leaf(leaf):
            if case .delegate = leaf { return leaf }
            return nil
        case let .sequence(items):
            return items.lazy.compactMap { self.firstDelegateLeaf(in: $0) }.first
        case let .returnWith(inner), let .group(_, _, inner), let .loop(inner):
            return firstDelegateLeaf(in: inner)
        case let .branch(_, then, otherwise):
            return firstDelegateLeaf(in: then) ?? firstDelegateLeaf(in: otherwise)
        case let .whileLoop(_, body):
            return firstDelegateLeaf(in: body)
        case .empty:
            return nil
        }
    }
}
