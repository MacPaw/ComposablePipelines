//
//  StateAndClientActionOperationTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import Foundation
import PipelineAST
@testable import ExecutionEngine

final class StateAndClientActionOperationTests: XCTestCase {

    private func makeContext(slots: [UUID: ExecutionValue] = [:]) -> ExecutionContext {
        ExecutionContext(initialSlots: slots)
    }

    // MARK: - StateSetOperation

    func testStateSetOperation_writesSlotAndReturnsValue() async throws {
        let slotID = UUID()
        let value = try JSONEncoder().encode("written")
        let ctx = makeContext()
        let op = StateSetOperation(context: ctx)
        let result = try await op.execute(
            slotID: slotID, valueTypeName: "String", debugLabel: "msg", value: value
        )
        XCTAssertEqual(result, value)
        let slotValue = await ctx.getSlot(slotID)
        XCTAssertEqual(slotValue, value)
    }

    func testStateSetOperation_emitsStateUpdate() async throws {
        let slotID = UUID()
        let value = try JSONEncoder().encode("hello")
        var updates: [StateUpdate] = []
        let ctx = ExecutionContext(
            eventObserver: { if case .stateUpdated(let u) = $0 { updates.append(u) } }
        )
        let op = StateSetOperation(context: ctx)
        _ = try await op.execute(
            slotID: slotID, valueTypeName: "String", debugLabel: nil, value: value
        )
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.slotID, slotID)
        XCTAssertEqual(updates.first?.value, value)
    }

    // MARK: - ClientActionOperation

    func testClientActionOperation_callsActionAndReturnsResult() async throws {
        let taskID = UUID()
        let input = try JSONEncoder().encode("ping")
        let ctx = ExecutionContext(
            clientActionProvider: PipelineWalker.clientActionProvider(from: [
                taskID: { _ in try JSONEncoder().encode("pong") },
            ])
        )
        let op = ClientActionOperation(context: ctx)
        let result = try await op.execute(taskID: taskID, inputValue: input)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "pong")
    }

    func testClientActionOperation_callsDynamicProviderWhenActionMissing() async throws {
        let taskID = UUID()
        let input = try JSONEncoder().encode("ping")
        let ctx = ExecutionContext(
            clientActionProvider: { requestedTaskID, input in
                XCTAssertEqual(requestedTaskID, taskID)
                XCTAssertEqual(try JSONDecoder().decode(String.self, from: input), "ping")
                return try JSONEncoder().encode("pong")
            }
        )
        let op = ClientActionOperation(context: ctx)
        let result = try await op.execute(taskID: taskID, inputValue: input)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "pong")
    }

    func testClientActionOperation_throwsWhenActionMissing() async throws {
        let taskID = UUID()
        let ctx = makeContext()
        let op = ClientActionOperation(context: ctx)
        do {
            _ = try await op.execute(taskID: taskID, inputValue: Data())
            XCTFail("Expected missingClientAction")
        } catch let error as ExecutionError {
            guard case .missingClientAction(let id) = error else {
                return XCTFail("Wrong error case: \(error)")
            }
            XCTAssertEqual(id, taskID)
        }
    }

    func testClientActionOperation_doesNotEmitStateUpdate() async throws {
        let taskID = UUID()
        var updates: [StateUpdate] = []
        let ctx = ExecutionContext(
            clientActionProvider: PipelineWalker.clientActionProvider(from: [taskID: { input in input }]),
            eventObserver: { if case .stateUpdated(let u) = $0 { updates.append(u) } }
        )
        let op = ClientActionOperation(context: ctx)
        _ = try await op.execute(taskID: taskID, inputValue: Data.emptyJSON)
        XCTAssertTrue(updates.isEmpty)
    }
}
