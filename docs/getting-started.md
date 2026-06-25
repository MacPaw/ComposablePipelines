# Getting started

This guide takes you from zero to a running pipeline: install the package, author a pipeline,
compile it, and walk it with your own executor.

## 1. Add the dependency

```swift
// Package.swift
.package(url: "https://github.com/MacPaw/ComposablePipelines", from: "0.1.0")
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ComposablePipelines", package: "ComposablePipelines"),
])
```

`import ComposablePipelines` re-exports the whole stack (DSL + AST + compiler + walker). If you
want a tighter surface, depend on the individual products instead:

| Product | Import | Role |
| --- | --- | --- |
| `PipelineAST` | `import PipelineAST` | The `Codable` graph a pipeline lowers to. Foundation-only. |
| `PipelineDSL` | `import PipelineDSL` | Authoring: `Pipeline`, `@PipelineBuilder`, `@State`, primitives. |
| `PipelineCompiler` | `import PipelineCompiler` | Lowered AST → optimized `PipelineExecutionGraph`. |
| `ExecutionEngine` | `import ExecutionEngine` | `PipelineWalker` + the `Executor` seam + `MockExecutor`. |

Requires Swift 5.9+, macOS 14+ / iOS 17+.

## 2. Author a pipeline

A pipeline is a `struct` conforming to `Pipeline`. Pin its `Output`, declare any shared state
with `@State`, and compose steps in `body` with `@PipelineBuilder`:

```swift
import ComposablePipelines

struct Chat: Pipeline {
    typealias Output = String
    let message: String

    var body: some Pipeline {
        Model<String, String>(
            instructions: "Answer the user clearly and concisely.",
            input: Just(value: message)
        )
    }
}
```

`Model<Input, Output>` is a leaf step. `Just(value:)` lifts a constant into a pipeline. Steps
don't pass typed values to each other directly — they share data through `@State` (see
[Primitives](primitives.md#state)).

## 3. Lower and compile

A pipeline lowers to a `Codable` AST (`PipelineGraph`), which the compiler turns into an
optimized execution plan (`PipelineExecutionGraph`):

```swift
let pipeline = Chat(message: "Hello!")
let graph    = PipelineCompiler().compile(pipeline.loweredGraph())
```

`PipelineCompiler(optimizations:)` defaults to `[.parallelize]` — independent steps are placed
in parallel batches. Use `.none` to keep strict sequential order.

## 4. Walk it with an executor

The walker orchestrates the run but never executes a model itself — it calls your `Executor`
for each model/guardrail step. `ExecutionValue` is a typealias for `Data` (UTF-8 JSON): decode
inputs, encode outputs.

```swift
struct EchoExecutor: Executor {
    func runModel(
        instructions: ExecutionValue, tools: ExecutionValue, input: ExecutionValue,
        outputTypeName: String, requirements: ModelSelectionRequirements?
    ) async throws -> ExecutionValue {
        let system = (try? JSONDecoder().decode(String.self, from: instructions)) ?? ""
        let text   = (try? JSONDecoder().decode(String.self, from: input)) ?? ""
        return try JSONEncoder().encode("[\(system)] \(text)")
    }

    func runGuardrail(rules: [GuardrailRule]) async throws -> ExecutionValue {
        try JSONEncoder().encode(true)   // true == passes
    }
}

let walker = PipelineWalker(executor: EchoExecutor())
let result = try await walker.run(graph: graph)

print(try JSONDecoder().decode(String.self, from: result))
// [Answer the user clearly and concisely.] Hello!
```

That's the full loop: **author → `loweredGraph()` → `compile` → `PipelineWalker.run`**.

## 5. Observe the run

`run(observingExecution:)` streams fine-grained `ExecutionEvent`s — step lifecycle, state
writes, parallel groups, and progress:

```swift
let result = try await walker.run(graph: graph) { event in
    switch event {
    case .stepStarted(let step):           print("▶︎ \(step.prettyLabel)")
    case .stepCompleted(let step, _, let ns): print("✓ \(step.prettyLabel) (\(ns) ns)")
    case .stateUpdated(let update):        print("· \(update.slotID) ←")
    default: break
    }
}
```

Every step-lifecycle event carries a `StepInfo` (`event.stepInfo`) and maps to a
`TaskExecutionStatus` (`event.taskStatus`), so you can maintain a live `[UUID:
TaskExecutionStatus]` snapshot. See [Executors](executors.md#observing-a-run).

## Where to next

- [Primitives](primitives.md) — every building block with real examples.
- [Executors](executors.md) — implement a real runtime behind the seam.
- [Architecture](architecture.md) — how compilation and incremental re-execution work.

> **Tip — running without a real backend.** `MockExecutor` lets the package run end to end with
> no models: model steps return an empty-string placeholder and guardrails pass. It's for
> exercising graph shape in demos and tests, not for real output.
