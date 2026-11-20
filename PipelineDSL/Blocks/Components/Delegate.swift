//
//  Delegate.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import PipelineAST

/// Spawn budget for a ``Delegate`` fan-out: a hard cap on how many subagents may run, plus a reserve of
/// slots that guarantee leaf forward-progress even under saturation.
public struct DelegateBudget: Sendable, Hashable {
    public var total: Int
    public var leafReserve: Int

    public init(total: Int, leafReserve: Int = 1) {
        self.total = total
        self.leafReserve = leafReserve
    }
}

/// A delegate of short-lived subagents, dispatched **agent-side**. Reads a list of tasks from `tasks`,
/// runs a prototype pipeline once per task — each in its own isolated scope, with the task value
/// seeded into `taskInput` — and gathers the distilled results in task order.
///
/// Unlike a client-side `ClientTask` fan-out, the delegate is a declarative leaf the agent walks itself:
/// every subagent runs in-process against the agent's shared model executor (one shared model
/// instance), bounded by ``DelegateBudget``. A subagent refused for lack of budget contributes `nil`.
///
/// The prototype is authored two ways:
/// - **inline** — a trailing `@PipelineBuilder` block (built at construction; the common case):
///   ```swift
///   Delegate(tasks: $questions, taskInput: $question, budget: .init(total: 32)) {
///       Model<String>().systemPrompt("Answer briefly.").input { $question.get() }
///   }
///   ```
/// - **prototype value** — any pipeline instance, incl. a *different* type (heterogeneous fan-out):
///   ```swift
///   Delegate(tasks: $tasks, taskInput: $task, budget: .init(total: 8), prototype: Summarizer())
///   ```
///
/// If the prototype's type is the **enclosing** pipeline (a self-delegate), the `prototype:` form detects
/// it during lowering and lowers to ``DelegateChild/selfRecursion`` instead of embedding — so
/// `Delegate(prototype: Agent())` inside `Agent` is safe and does not recurse forever at build time. Note
/// this detection only fires for a delegate reached *while lowering the enclosing type*: the **outermost**
/// `Delegate(prototype: Self())` (lowered before any `PipelineLoweringGuard` scope is entered) still
/// embeds one copy of the graph, and only nested self-prototypes collapse to `selfRecursion`. For an
/// explicit, output-typed self-delegate that avoids the extra embedded copy entirely, use ``DelegateSelf``.
///
/// - Author: Claude
public struct Delegate<Task, Child: Pipeline>: LeafPipeline
where Task: Codable & Hashable & Sendable {
    public typealias Output = [Child.Output?]

    /// How the per-task prototype is sourced. Inline blocks are built eagerly (stable slot ids); a
    /// `prototype:` value is built lazily at lowering so ``PipelineLoweringGuard`` can catch a
    /// self-referential prototype before it recurses.
    private enum ChildSource {
        case built(Child)
        case lazy(() -> Child)
    }

    /// Slot holding the task list; the delegate reads it at execution time.
    public let tasks: Binding<[Task]>
    /// Slot each task value is seeded into for the child run — the child reads it via `.get()`.
    public let taskInput: Binding<Task>
    public let budget: DelegateBudget
    /// Which of the parent run's capabilities each subagent inherits. Defaults to
    /// ``DelegateInheritance/isolated`` — a child sees only its seeded task, and the parent opts in to
    /// the tools / context / memory a child actually needs.
    public let inherit: DelegateInheritance
    private let source: ChildSource

    /// Inline prototype: the trailing block is built now, so its `@State` slot ids are fixed.
    public init(
        tasks: Binding<[Task]>,
        taskInput: Binding<Task>,
        budget: DelegateBudget,
        inherit: DelegateInheritance = .isolated,
        @PipelineBuilder child: () -> Child
    ) {
        self.tasks = tasks
        self.taskInput = taskInput
        self.budget = budget
        self.inherit = inherit
        self.source = .built(child())
    }

    /// Prototype value: built **lazily** at lowering (not construction), so a self-referential
    /// prototype (`Delegate(prototype: Self())`) is caught by ``PipelineLoweringGuard`` and lowered to
    /// self-recursion instead of looping forever while building the graph.
    public init(
        tasks: Binding<[Task]>,
        taskInput: Binding<Task>,
        budget: DelegateBudget,
        inherit: DelegateInheritance = .isolated,
        prototype: @autoclosure @escaping () -> Child
    ) {
        self.tasks = tasks
        self.taskInput = taskInput
        self.budget = budget
        self.inherit = inherit
        self.source = .lazy(prototype)
    }

    public var pipelineGraph: PipelineGraph {
        func leaf(_ child: DelegateChild<PipelineGraph>) -> PipelineGraph {
            .leaf(.delegate(
                child: child,
                tasksSlotID: tasks.id,
                taskInputSlotID: taskInput.id,
                budgetTotal: budget.total,
                leafReserve: budget.leafReserve,
                inherit: inherit
            ))
        }
        switch source {
        case let .built(child):
            return leaf(.embedded(child.pipelineGraph))
        case let .lazy(make):
            // A prototype of the enclosing type is self-recursion; embedding it would never terminate.
            if PipelineLoweringGuard.isLowering(Child.self) {
                return leaf(.selfRecursion)
            }
            return PipelineLoweringGuard.lowering(Child.self) {
                leaf(.embedded(make().pipelineGraph))
            }
        }
    }
}

/// An explicit **self-cloning** fan-out: each subagent re-runs the **enclosing** agent pipeline — a
/// delegate of itself — one level deeper, seeded with its own subtask. Reads the subtasks from `tasks`
/// and gathers `[Element?]` (the enclosing pipeline's output per subtask; `nil` for a budget-refused
/// delegate).
///
/// Prefer this over `Delegate(prototype: Self())` when you want an explicit, output-typed self-delegate that
/// is guaranteed to compile (it never mentions the enclosing type, so it sidesteps recursive-type and
/// opaque-return pitfalls). Termination rests on the shared spawn budget (`DelegateBudget`).
///
/// ```swift
/// struct Agent: Pipeline {
///     @State var subtasks: [String] = []
///     @State var subtask: String = ""
///     var body: some Pipeline {
///         // … decide subtasks …
///         DelegateSelf<String, String>(tasks: $subtasks, taskInput: $subtask, budget: .init(total: 16))
///         // … synthesize the gathered delegate answers …
///     }
/// }
/// ```
///
/// - Author: Claude
public struct DelegateSelf<Task, Element>: LeafPipeline
where Task: Codable & Hashable & Sendable {
    /// `Element` is an **unchecked phantom**: it only shapes the static `Output` and is never reconciled
    /// with the enclosing pipeline's actual output type (the executed graph is untyped). Set it to the
    /// enclosing pipeline's `Output` yourself — the compiler will not catch a mismatch.
    public typealias Output = [Element?]

    /// Slot holding the subtask list; the delegate reads it at execution time.
    public let tasks: Binding<[Task]>
    /// Slot each subtask is seeded into for the delegate run.
    public let taskInput: Binding<Task>
    public let budget: DelegateBudget
    /// Which of the parent run's capabilities each delegate inherits (isolated state regardless).
    public let inherit: DelegateInheritance

    public init(
        tasks: Binding<[Task]>,
        taskInput: Binding<Task>,
        budget: DelegateBudget,
        inherit: DelegateInheritance = .isolated
    ) {
        self.tasks = tasks
        self.taskInput = taskInput
        self.budget = budget
        self.inherit = inherit
    }

    public var pipelineGraph: PipelineGraph {
        .leaf(.delegate(
            child: .selfRecursion,
            tasksSlotID: tasks.id,
            taskInputSlotID: taskInput.id,
            budgetTotal: budget.total,
            leafReserve: budget.leafReserve,
            inherit: inherit
        ))
    }
}
