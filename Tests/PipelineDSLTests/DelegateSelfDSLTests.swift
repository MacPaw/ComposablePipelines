//
//  DelegateSelfDSLTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
@testable import PipelineDSL

/// Self-cloning DSL — Step 2. Covers the explicit `DelegateSelf` form, the heterogeneous
/// `Delegate(prototype:)` form, and the self-detection guard that turns a self-referential
/// `Delegate(prototype: Self())` into `.selfRecursion` at lowering (instead of looping forever).
final class DelegateSelfDSLTests: XCTestCase {

    // MARK: - Explicit DelegateSelf

    private struct ExplicitSelfPipeline: Pipeline {
        typealias Output = String
        @State var subtasks: [String] = ["a", "b"]
        @State var subtask: String = ""
        @State var answers: [String?] = []
        @State var final: String = "done"

        var body: some Pipeline {
            $answers.set {
                DelegateSelf<String, String>(tasks: $subtasks, taskInput: $subtask, budget: .init(total: 8))
            }
            $final.get()
        }
    }

    func testDelegateSelfLowersToSelfRecursion() throws {
        let leaf = try XCTUnwrap(firstDelegateLeaf(in: ExplicitSelfPipeline().loweredGraph()))
        guard case let .delegate(child, _, _, budgetTotal, _, _) = leaf else {
            return XCTFail("expected a .delegate leaf")
        }
        XCTAssertEqual(child, .selfRecursion, "DelegateSelf must lower to a self-recursion child")
        XCTAssertEqual(budgetTotal, 8)
    }

    // MARK: - Heterogeneous Delegate(prototype:) — a different type embeds

    private struct Leafy: Pipeline {
        typealias Output = String
        @State var value: String = ""
        var body: some Pipeline { $value.get() }
    }

    private struct EmbedOtherPipeline: Pipeline {
        typealias Output = [String?]
        @State var tasks: [String] = ["a"]
        @State var task: String = ""
        var body: some Pipeline {
            Delegate(tasks: $tasks, taskInput: $task, budget: .init(total: 4), prototype: Leafy())
        }
    }

    func testDelegatePrototypeOfAnotherTypeEmbeds() throws {
        let leaf = try XCTUnwrap(firstDelegateLeaf(in: EmbedOtherPipeline().loweredGraph()))
        guard case let .delegate(child, _, _, _, _, _) = leaf else { return XCTFail("expected a .delegate leaf") }
        guard case .embedded = child else {
            return XCTFail("a prototype of a different type must embed, not self-recurse")
        }
    }

    // MARK: - Self-detection guard: Delegate(prototype: Self()) → self-recursion

    private struct SelfProtoAgent: Pipeline {
        typealias Output = String
        @State var subtasks: [String] = ["x"]
        @State var subtask: String = ""
        @State var answers: [String?] = []
        @State var final: String = "done"

        var body: some Pipeline {
            $answers.set {
                Delegate(tasks: $subtasks, taskInput: $subtask, budget: .init(total: 4), prototype: SelfProtoAgent())
            }
            $final.get()
        }
    }

    func testDelegatePrototypeOfSelfAutodetectsSelfRecursion() throws {
        // Lowering must terminate (the guard prevents infinite embedding) …
        let graph = SelfProtoAgent().loweredGraph()

        // … the top-level delegate embeds exactly one copy of the agent body …
        let top = try XCTUnwrap(firstDelegateLeaf(in: graph))
        guard case let .delegate(topChild, _, _, _, _, _) = top,
              case let .embedded(childGraph) = topChild else {
            return XCTFail("the outermost self-delegate embeds one agent copy")
        }

        // … whose own nested delegate is resolved to self-recursion (not another embed → no infinite tree).
        let nested = try XCTUnwrap(firstDelegateLeaf(in: childGraph))
        guard case let .delegate(nestedChild, _, _, _, _, _) = nested else {
            return XCTFail("expected a nested .delegate leaf")
        }
        XCTAssertEqual(nestedChild, .selfRecursion,
                       "a prototype of the enclosing type must lower to self-recursion, not embed forever")
    }

    // MARK: - Helper

    private func firstDelegateLeaf(in graph: PipelineGraph) -> PipelineGraphLeaf? {
        switch graph {
        case let .leaf(leaf):
            if case .delegate = leaf { return leaf }
            if case let .executionStateSet(_, _, value, _, _) = leaf { return firstDelegateLeaf(in: value) }
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
