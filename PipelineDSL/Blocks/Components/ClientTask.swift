//
//  ClientTask.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

public struct ClientTask<Input: Sendable & Codable & Hashable, Output: Sendable & Codable & Hashable>: LeafPipeline {

    @_spi(Internals) public let taskID: UUID
    public let input: () -> any Pipeline
    public let action: (@Sendable (Input) async throws -> Output)?
    @_spi(Internals) public let erasedAction: PipelineClientAction

    public init<InputPipeline: Pipeline>(
        taskID: UUID = UUID(),
        @PipelineBuilder input: @Sendable @escaping () -> InputPipeline,
        action: @escaping @Sendable (Input) async throws -> Output
    ) where InputPipeline.Output == Input {
        self.taskID = taskID
        self.input = { input().representedAsPipeline }
        self.action = action
        self.erasedAction = { data in
            let input = try JSONDecoder().decode(Input.self, from: data)
            let output = try await action(input)
            return try JSONEncoder().encode(output)
        }
    }

    public init(
        taskID: UUID = UUID(),
        input: Binding<Input>,
        action: @escaping @Sendable (Input) async throws -> Output
    ) {
        self.taskID = taskID
        self.input = { input.representedAsPipeline }
        self.action = action
        self.erasedAction = { data in
            let input = try JSONDecoder().decode(Input.self, from: data)
            let output = try await action(input)
            return try JSONEncoder().encode(output)
        }
    }

    public init(
        taskID: UUID = UUID(),
        action: @escaping @Sendable () async throws -> Output
    ) where Input == Never {
        self.taskID = taskID
        self.input = { EmptyPipeline().representedAsPipeline }
        self.action = nil
        self.erasedAction = { _ in
            let output = try await action()
            return try JSONEncoder().encode(output)
        }
    }
}

extension ClientTask {
    public func execute(_ input: Input) async throws -> Output {
        guard let action else {
            fatalError("No typed action is available for no-input ClientTask")
        }
        return try await action(input)
    }
}

extension ClientTask where Input == Never {
    public func execute() async throws -> Output {
        let data = try await erasedAction(Data())
        return try JSONDecoder().decode(Output.self, from: data)
    }
}

extension ClientTask {
    public var pipelineGraph: PipelineGraph {
        GraphEmissionContext.current?.recordClientAction(taskID: taskID, action: erasedAction)
        return .leaf(
            .clientAction(taskID: taskID, input: input().pipelineGraph)
        )
    }
}
