//
//  Model.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import PipelineAST

/// LLM-style step; **instructions**, **tools**, and **input** each lower to their own subgraphs (see ``PipelineGraphLeaf/model``).
///
/// Initializers take ``PipelineConvertible`` and/or ``@PipelineBuilder`` closures; all paths normalize through ``PipelineConvertible/representedAsPipeline``.
public struct Model<Input: Sendable & Codable & Hashable, Output: ModelOutput>: LeafPipeline {

    public let requirements: ModelSelectionRequirements?
    public let instructions: any Pipeline
    public let tools: any Pipeline
    public let input: any Pipeline
    let executors: [any PipelineTool]

    // MARK: - Pipeline-based tools (descriptor subgraph only)

    public init<Instr: Pipeline, ToolsP: Pipeline, InP: Pipeline>(
        requirements: ModelSelectionRequirements? = nil,
        @PipelineBuilder instructions: @escaping () -> Instr,
        @PipelineBuilder tools: @escaping () -> ToolsP,
        @PipelineBuilder input: @escaping () -> InP
    ) where Instr.Output == String, InP.Output == Input {
        self.instructions = instructions().representedAsPipeline
        self.tools = tools().representedAsPipeline
        self.input = input().representedAsPipeline
        self.requirements = requirements
        self.executors = []
    }

    public init<Instr: PipelineConvertible, ToolsP: Pipeline, InP: Pipeline>(
        requirements: ModelSelectionRequirements? = nil,
        instructions: Instr,
        @PipelineBuilder tools: @escaping () -> ToolsP,
        @PipelineBuilder input: @escaping () -> InP
    ) where InP.Output == Input {
        self.instructions = instructions.representedAsPipeline
        self.tools = tools().representedAsPipeline
        self.input = input().representedAsPipeline
        self.requirements = requirements
        self.executors = []
    }

    // MARK: - No tools

    public init<Instr: Pipeline, InP: Pipeline>(
        requirements: ModelSelectionRequirements? = nil,
        @PipelineBuilder instructions: @escaping () -> Instr,
        @PipelineBuilder input: @escaping () -> InP
    ) where Instr.Output == String, InP.Output == Input {
        self.instructions = instructions().representedAsPipeline
        self.tools = EmptyPipeline().representedAsPipeline
        self.input = input().representedAsPipeline
        self.requirements = requirements
        self.executors = []
    }

    public init<Instr: PipelineConvertible, InP: Pipeline>(
        requirements: ModelSelectionRequirements? = nil,
        instructions: Instr,
        @PipelineBuilder input: @escaping () -> InP
    ) where InP.Output == Input {
        self.instructions = instructions.representedAsPipeline
        self.tools = EmptyPipeline().representedAsPipeline
        self.input = input().representedAsPipeline
        self.requirements = requirements
        self.executors = []
    }

    public init<Instr: PipelineConvertible, InP: PipelineConvertible>(
        requirements: ModelSelectionRequirements? = nil,
        instructions: Instr,
        input: InP
    ) where InP.Output == Input {
        self.instructions = instructions.representedAsPipeline
        self.tools = EmptyPipeline().representedAsPipeline
        self.input = input.representedAsPipeline
        self.requirements = requirements
        self.executors = []
    }

    // MARK: - Tools

    public init<Instr: PipelineConvertible, InP: PipelineConvertible>(
        requirements: ModelSelectionRequirements? = nil,
        instructions: Instr,
        tools: [any PipelineTool],
        input: InP
    ) where InP.Output == Input {
        self.instructions = instructions.representedAsPipeline
        self.tools = Just(value: ToolEncoding.encode(tools.map(\.descriptor))).representedAsPipeline
        self.input = input.representedAsPipeline
        self.requirements = requirements
        self.executors = tools
    }

    public init<Instr: PipelineConvertible, InP: Pipeline>(
        requirements: ModelSelectionRequirements? = nil,
        instructions: Instr,
        tools: [any PipelineTool],
        @PipelineBuilder input: @escaping () -> InP
    ) where InP.Output == Input {
        self.instructions = instructions.representedAsPipeline
        self.tools = Just(value: ToolEncoding.encode(tools.map(\.descriptor))).representedAsPipeline
        self.input = input().representedAsPipeline
        self.requirements = requirements
        self.executors = tools
    }

    // MARK: - Graph emission

    public var pipelineGraph: PipelineGraph {
        if !executors.isEmpty {
            GraphEmissionContext.current?.registerTools(executors)
        }
        return .leaf(
            .model(
                instructions: instructions.pipelineGraph,
                tools: tools.pipelineGraph,
                input: input.pipelineGraph,
                outputTypeName: String(describing: Output.self),
                requirements: requirements
            )
        )
    }
}

extension Model where Input == Never, Output == String {
    public init(requirements: ModelSelectionRequirements? = nil, instructions: String) {
        self.requirements = requirements
        self.instructions = instructions.representedAsPipeline
        self.tools = EmptyPipeline().representedAsPipeline
        self.input = EmptyPipeline().representedAsPipeline
        self.executors = []
    }
}

public protocol ModelOutput: Codable, Hashable, Sendable {}

extension String: ModelOutput {}
extension ModelTurn: ModelOutput {}
