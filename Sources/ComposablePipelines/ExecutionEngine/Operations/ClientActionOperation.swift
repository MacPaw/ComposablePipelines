//
//  ClientActionOperation.swift
//  elix-toolchain
//
//  Created by Oleksandr Frankiv on 23.04.2026.
//

import Foundation

/// Executes a `.clientAction` operation: calls the registered client closure
/// with a pre-resolved input value and returns the encoded result.
///
/// The calling `GraphWalker` is responsible for walking the input subgraph
/// before invoking `execute`; this struct only handles dispatch.
struct ClientActionOperation: Sendable {

    let context: ExecutionContext

    func execute(taskID: UUID, inputValue: ExecutionValue) async throws -> ExecutionValue {
        try await context.executeClientAction(taskID: taskID, input: inputValue)
    }
}
