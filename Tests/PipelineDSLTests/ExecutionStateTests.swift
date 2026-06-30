//
//  ExecutionStateTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
@testable import PipelineDSL

final class ExecutionStateTests: XCTestCase {

    func test_eachInstance_getsUniqueID() {
        let a = State<String>(wrappedValue: "")
        let b = State<String>(wrappedValue: "")
        XCTAssertNotEqual(a.id, b.id)
    }

    func test_valueTypeName_matchesGenericParameter() {
        let stringState = State<String>(wrappedValue: "")
        XCTAssertEqual(stringState.valueTypeName, "String")

        let intState = State<Int>(wrappedValue: 0)
        XCTAssertEqual(intState.valueTypeName, "Int")
    }

    func test_singleKey_JSONRoundTrip() throws {
        let original = State<String>(wrappedValue: "hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(State<String>.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_setOfStates_JSONCodable_roundTrip() throws {
        let a = State<String>(wrappedValue: "x")
        let b = State<String>(wrappedValue: "y")
        let original: Set<State<String>> = [a, b]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Set<State<String>>.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
