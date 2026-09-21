//
//  ContextProvideOperation.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Way Ltd. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Executes a `.contextProvide` operation: decodes the query string from the
/// pre-resolved input, calls the registered ``ContextItemsProvider``, and
/// returns the items encoded as JSON.
///
/// The calling `GraphWalker` is responsible for walking the query subgraph
/// before invoking `execute`; this struct only handles dispatch.
struct ContextProvideOperation: Sendable {

    let context: ExecutionContext

    func execute(providerID: UUID, queryValue: ExecutionValue) async throws -> ExecutionValue {
        let query = try JSONDecoder().decode(String.self, from: queryValue)
        let items = try await context.executeContextProvide(providerID: providerID, query: query)
        return try JSONEncoder().encode(items)
    }
}
