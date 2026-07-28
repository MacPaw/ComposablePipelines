//
//  RunConstructionTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
@_spi(Internals) @testable import PipelineDSL

final class RunConstructionTests: XCTestCase {

    // MARK: - Lowering shapes

    private struct SingleInputFixture: Pipeline {
        typealias Output = Int
        @State var text = "hello world"

        var body: some Pipeline {
            Run($text) { $0.count }
        }
    }

    func testRun_singleBinding_lowersToClientActionWithStateGetInput() {
        let graph = SingleInputFixture().loweredGraph()

        guard case let .leaf(.clientAction(_, input)) = graph else {
            return XCTFail("expected clientAction leaf, got:\n\(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        guard case let .leaf(.executionStateGet(_, valueTypeName, _, _)) = input else {
            return XCTFail("expected stateGet input, got:\n\(PipelineGraphTestHelpers.prettyPrint(input))")
        }
        XCTAssertEqual(valueTypeName, "String")
    }

    private struct TwoInputFixture: Pipeline {
        typealias Output = String
        @State var greeting = "Hello"
        @State var name = "World"

        var body: some Pipeline {
            Run($greeting, $name) { greeting, name in "\(greeting), \(name)!" }
        }
    }

    func testRun_twoBindings_lowersToCombineOfStateGets() {
        let graph = TwoInputFixture().loweredGraph()

        guard case let .leaf(.clientAction(_, input)) = graph else {
            return XCTFail("expected clientAction leaf, got:\n\(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        guard case let .leaf(.combine(parts)) = input else {
            return XCTFail("expected combine input, got:\n\(PipelineGraphTestHelpers.prettyPrint(input))")
        }
        XCTAssertEqual(parts.count, 2)
        for part in parts {
            guard case .leaf(.executionStateGet(_, _, _, _)) = part else {
                return XCTFail("expected stateGet part, got:\n\(PipelineGraphTestHelpers.prettyPrint(part))")
            }
        }
    }

    private struct MapAssignFixture: Pipeline {
        typealias Output = Int
        @State var text = "abc"
        @State var count = 0

        var body: some Pipeline {
            $text.map(\.count).assign(to: $count)
            $count.get()
        }
    }

    func testMapAssign_lowersToStateSetWrappingClientAction() {
        let graph = MapAssignFixture().loweredGraph()

        guard case let .sequence(steps) = graph, steps.count == 2 else {
            return XCTFail("expected two-step sequence, got:\n\(PipelineGraphTestHelpers.prettyPrint(graph))")
        }
        guard case let .leaf(.executionStateSet(_, valueTypeName, value, _, writeKind)) = steps[0] else {
            return XCTFail("expected stateSet, got:\n\(PipelineGraphTestHelpers.prettyPrint(steps[0]))")
        }
        XCTAssertEqual(valueTypeName, "Int")
        XCTAssertEqual(writeKind, .commit)
        guard case .leaf(.clientAction(_, _)) = value else {
            return XCTFail("expected clientAction value, got:\n\(PipelineGraphTestHelpers.prettyPrint(value))")
        }
    }

    // MARK: - Stable task identity

    func testRun_stableID_derivesDeterministicTaskID() {
        let binding = Binding(state: State(wrappedValue: "x"))
        let first = Run<String, Int>(id: "word-count", binding) { $0.count }
        let second = Run<String, Int>(id: "word-count", binding) { $0.count }

        XCTAssertEqual(first.taskID, second.taskID)
        XCTAssertEqual(first.taskID, UUID(stableTaskName: "word-count"))
        let other = Run<String, Int>(id: "other-task", binding) { $0.count }
        XCTAssertNotEqual(first.taskID, other.taskID)
    }

    func testRun_withoutID_generatesUniqueTaskIDs() {
        let binding = Binding(state: State(wrappedValue: "x"))
        let first = Run<String, Int>(binding) { $0.count }
        let second = Run<String, Int>(binding) { $0.count }
        XCTAssertNotEqual(first.taskID, second.taskID)
    }

    func testUUIDStableTaskName_isWellFormedAndStable() {
        let uuid = UUID(stableTaskName: "fetch-locale")
        XCTAssertEqual(uuid, UUID(stableTaskName: "fetch-locale"))
        XCTAssertNotEqual(uuid, UUID(stableTaskName: "fetch-locales"))
        // Version 8 (custom) + RFC 4122 variant bits.
        let string = uuid.uuidString
        XCTAssertEqual(string[string.index(string.startIndex, offsetBy: 14)], "8")
    }

    // MARK: - Combined values

    func testCombined2_codesAsJSONArray() throws {
        let pair = Combined2("a", 1)
        let data = try JSONEncoder().encode(pair)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"a\",1]")
        XCTAssertEqual(try JSONDecoder().decode(Combined2<String, Int>.self, from: data), pair)
    }

    func testCombined3_codesAsJSONArray() throws {
        let triple = Combined3("a", 1, true)
        let data = try JSONEncoder().encode(triple)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"a\",1,true]")
        XCTAssertEqual(try JSONDecoder().decode(Combined3<String, Int, Bool>.self, from: data), triple)
    }

    // MARK: - Source compatibility

    func testClientTaskAlias_stillResolves() {
        let binding = Binding(state: State(wrappedValue: "x"))
        let task = ClientTask(input: binding) { (text: String) in text.count }
        XCTAssertNotNil(task.action)
    }
}
