//
//  ContextProvideOperationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
@testable import ExecutionEngine

final class ContextProvideOperationTests: XCTestCase {

    // MARK: - Mock

    private actor MockProvider: ContextItemsProvider {
        let sourceID: ContextSourceID
        let items: [ContextItem]
        private(set) var receivedQueries: [String] = []

        init(sourceID: ContextSourceID = "mock", items: [ContextItem]) {
            self.sourceID = sourceID
            self.items = items
        }

        func fetch(query: String) async throws -> [ContextItem] {
            receivedQueries.append(query)
            return items
        }
    }

    // MARK: - Helpers

    private func encode(_ string: String) throws -> ExecutionValue {
        try JSONEncoder().encode(string)
    }

    private func decodeItems(_ value: ExecutionValue) throws -> [ContextItem] {
        try JSONDecoder().decode([ContextItem].self, from: value)
    }

    // MARK: - Tests

    func testReturnsItemsFromRegisteredProvider() async throws {
        let providerID = UUID()
        let expected = [
            ContextItem(kind: .custom("a"), source: "mock", value: "one"),
            ContextItem(kind: .custom("b"), source: "mock", value: "two")
        ]
        let provider = MockProvider(items: expected)
        let context = ExecutionContext(
            contextProviders: [providerID: provider]
        )
        let op = ContextProvideOperation(context: context)

        let out = try await op.execute(
            providerID: providerID,
            queryValue: try encode("hello")
        )
        XCTAssertEqual(try decodeItems(out), expected)
    }

    func testForwardsQueryStringToProvider() async throws {
        let providerID = UUID()
        let provider = MockProvider(items: [])
        let context = ExecutionContext(
            contextProviders: [providerID: provider]
        )
        let op = ContextProvideOperation(context: context)

        _ = try await op.execute(providerID: providerID, queryValue: try encode("what time is it?"))
        let queries = await provider.receivedQueries
        XCTAssertEqual(queries, ["what time is it?"])
    }

    func testMissingProviderThrows() async throws {
        let context = ExecutionContext()
        let op = ContextProvideOperation(context: context)
        let unknownID = UUID()

        do {
            _ = try await op.execute(providerID: unknownID, queryValue: try encode("x"))
            XCTFail("expected ExecutionError.missingContextProvider")
        } catch let ExecutionError.missingContextProvider(providerID) {
            XCTAssertEqual(providerID, unknownID)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
