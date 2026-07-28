//
//  RunClientTaskTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import XCTest
import PipelineAST
import PipelineCompiler
@_spi(Internals) @testable import PipelineDSL
@testable import ExecutionEngine

/// End-to-end coverage for the `Run` (né `ClientTask`) sugar through the real
/// lower → compile → walk path: single/multi-binding inputs, `Binding.map`,
/// `assign(to:)`, and stable-`id:` dispatch across an encode/decode round trip.
final class RunClientTaskTests: XCTestCase {

    // MARK: - Single binding

    private struct WordCount: Pipeline {
        typealias Output = Int
        @State var text = "one two three"

        var body: some Pipeline {
            Run($text) { $0.split(whereSeparator: \.isWhitespace).count }
        }
    }

    func testRun_singleBinding_receivesSlotValue() async throws {
        let (result, _) = try await PipelineRun.runOnce(WordCount(), executor: MockExecutor())
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: result), 3)
    }

    // MARK: - Multi-binding combine

    private struct Greeting: Pipeline {
        typealias Output = String
        @State var greeting = "Hello"
        @State var name = "World"

        var body: some Pipeline {
            Run($greeting, $name) { greeting, name in "\(greeting), \(name)!" }
        }
    }

    func testRun_twoBindings_receivesBothSlotValues() async throws {
        let (result, _) = try await PipelineRun.runOnce(Greeting(), executor: MockExecutor())
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "Hello, World!")
    }

    private struct ThreeWay: Pipeline {
        typealias Output = String
        @State var a = "x"
        @State var b = "y"
        @State var c = "z"

        var body: some Pipeline {
            Run($a, $b, $c) { a, b, c in a + b + c }
        }
    }

    func testRun_threeBindings_receivesAllSlotValues() async throws {
        let (result, _) = try await PipelineRun.runOnce(ThreeWay(), executor: MockExecutor())
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "xyz")
    }

    // MARK: - map + assign

    private struct MappedCount: Pipeline {
        typealias Output = Int
        @State var text = "abcde"
        @State var length = 0

        var body: some Pipeline {
            $text.map(\.count).assign(to: $length)
            $length.get()
        }
    }

    func testMapKeyPath_assignWritesTransformedValueToSlot() async throws {
        let (result, _) = try await PipelineRun.runOnce(MappedCount(), executor: MockExecutor())
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: result), 5)
    }

    // MARK: - Stable identity across the wire

    private struct FetchLocale: Pipeline {
        typealias Output = String

        var body: some Pipeline {
            Run(id: "fetch-locale") { "uk_UA" }
        }
    }

    /// Encoding the lowered graph drops the closure registry — exactly what happens when a
    /// graph crosses the wire. The host must be able to dispatch by the *derived* stable UUID.
    func testNoInputRun_stableID_dispatchesAfterEncodeDecodeRoundTrip() async throws {
        let data = try FetchLocale().encodedLoweredGraph()
        let decoded = try PipelineGraph.decode(from: data)
        let graph = PipelineCompiler(optimizations: [.parallelize]).compile(decoded)

        let walker = PipelineWalker(executor: MockExecutor())
        let result = try await walker.run(
            graph: graph,
            clientActionProvider: { taskID, _ in
                XCTAssertEqual(taskID, UUID(stableTaskName: "fetch-locale"))
                return try JSONEncoder().encode("uk_UA")
            }
        )
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "uk_UA")
    }
}
