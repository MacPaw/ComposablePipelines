# Composable Pipelines

A composable, runtime-agnostic stack for building AI pipelines in Swift: a SwiftUI-like
DSL, a `Codable` AST, a compiler that lowers it to an execution graph, and an **observable
walker** that orchestrates the run while you supply how each operation actually executes.

```swift
struct Summarize: Pipeline {
    @State var draft: String = ""

    var body: some Pipeline {
        Model(.instruct)            // "summarize the input"
            .writing(to: $draft)
        Guardrail(.pii)             // gate the result
    }
}
```

You author a pipeline, compile it, and walk it with an executor of your choosing.

## Modules

| Module | Role |
| --- | --- |
| **PipelineAST** | The `Codable` graph a pipeline lowers to — the stable transport boundary. Encode it on a client, decode it on a backend. Foundation-only. |
| **PipelineDSL** | The authoring surface: the `Pipeline` protocol, `@PipelineBuilder`, `@State`, and primitives (`Model`, `Guardrail`, `While`, `Group`, `ClientTask`, `ForEach`, `Summarize`). |
| **PipelineCompiler** | Lowers the AST into a `PipelineExecutionGraph` via dependency analysis, slot-hazard ordering, gate/barrier construction, and topological grouping. |
| **ExecutionEngine** | The observable **`PipelineWalker`** — follows the execution graph, drives epoch-based incremental re-execution, parallel batching, and state, and emits `ExecutionEvent`s. It delegates the actual work of each operation to an **`Executor`** you provide. |

## The Executor seam

The walker never executes operations itself. For each model/guardrail/tool step it calls an
`Executor` you implement — so you decide what "run a model" means (a local model, a hosted
API, a remote service, anything):

```swift
struct MyExecutor: Executor {
    func runModel(instructions: ExecutionValue, tools: ExecutionValue, input: ExecutionValue,
                  outputTypeName: String, requirements: ModelSelectionRequirements?) async throws -> ExecutionValue {
        // call your model of choice, return the encoded result
    }
    func runGuardrail(rules: [GuardrailRule]) async throws -> ExecutionValue { /* ... */ }
}

let graph = try PipelineCompiler().compile(Summarize())
let walker = PipelineWalker(executor: MyExecutor())
let result = try await walker.run(graph: graph) { event in
    // observe progress: event.stepInfo, event.taskStatus, state updates...
}
```

A `MockExecutor` ships so the package runs end-to-end out of the box for demos and tests.

## Install

```swift
.package(url: "https://github.com/MacPaw/ComposablePipelines", from: "0.1.0")
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "PipelineDSL", package: "ComposablePipelines"),
    .product(name: "PipelineCompiler", package: "ComposablePipelines"),
    .product(name: "ExecutionEngine", package: "ComposablePipelines"),
])
```

Requires Swift 5.9+, macOS 14+ / iOS 17+.

## License

Apache License 2.0 — © MacPaw Inc. See [LICENSE](LICENSE).

## A note on this repository

This repository is a **mirror**. The source of truth lives in MacPaw's monorepo and is
exported here one-directionally. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening
issues or pull requests.
