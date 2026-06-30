# Composable Pipelines

![Composable Pipelines](.github/header.png)

A composable, runtime-agnostic stack for building AI pipelines in Swift: a SwiftUI-like
**DSL**, a `Codable` **AST**, a **compiler** that lowers it to an execution graph, and an
observable **walker** that orchestrates the run — while *you* supply how each operation
actually executes.

```swift
import ComposablePipelines

struct Summary: Pipeline {
    typealias Output = String
    let document: String

    @State var keyPoints = ""
    @State var summary = ""

    var body: some Pipeline {
        Guardrail(rules: [.pii])                       // gate the input
        $keyPoints.set {                               // step 1 → slot
            Model<String, String>(
                instructions: "Extract the 5 key points.",
                input: Just(value: document)
            )
        }
        $summary.set {                                 // step 2 reads step 1
            Model<String, String>(
                instructions: "Write a concise summary from these points.",
                input: $keyPoints.get()
            )
        }
        $summary.get()                                 // pipeline output
    }
}
```

You **author** a pipeline, **compile** it to a graph, and **walk** it with an executor of
your choosing. The walker handles ordering, parallelism, state, and incremental
re-execution; the executor decides what "run a model" actually means.

## Why

- **SwiftUI-like authoring.** Declare *intent* with `@PipelineBuilder`, `@State`, and native
  `if`/`switch`. No manual graph wiring.
- **Bring your own runtime.** The walker never runs a model itself — it calls an `Executor`
  you implement (a local model, a hosted API, a remote service, anything).
- **The AST is the wire format.** A pipeline lowers to a `Codable` graph: encode it on a
  client, decode and run it on a backend (or vice-versa). The same pipeline crosses the wire.
- **Incremental re-execution.** State writes advance an epoch; on re-evaluation the walker
  skips the unchanged graph prefix instead of re-running completed work.
- **Dependency-light.** Resolves on Foundation, swift-syntax, and AnyLanguageModel — no
  proprietary dependencies.

## Install

```swift
.package(url: "https://github.com/MacPaw/ComposablePipelines", from: "0.1.0")
```

The umbrella product re-exports the whole stack:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ComposablePipelines", package: "ComposablePipelines"),
])
```

```swift
import ComposablePipelines   // one import: DSL + AST + compiler + walker
```

Prefer narrower imports? Depend on the individual products instead — `PipelineAST`,
`PipelineDSL`, `PipelineCompiler`, `ExecutionEngine`.

Requires Swift 5.9+, macOS 14+ / iOS 17+.

## Run it end to end

The walker delegates each model/guardrail step to your `Executor`:

```swift
import ComposablePipelines

struct EchoExecutor: Executor {
    func runModel(
        instructions: ExecutionValue, tools: ExecutionValue, input: ExecutionValue,
        outputTypeName: String, requirements: ModelSelectionRequirements?
    ) async throws -> ExecutionValue {
        let system = (try? JSONDecoder().decode(String.self, from: instructions)) ?? ""
        let text   = (try? JSONDecoder().decode(String.self, from: input)) ?? ""
        return try JSONEncoder().encode("[\(system)] \(text)")   // call a real model here
    }

    func runGuardrail(rules: [GuardrailRule]) async throws -> ExecutionValue {
        try JSONEncoder().encode(true)                            // true == passes
    }
}

let pipeline = Summary(document: "…")
let graph    = PipelineCompiler().compile(pipeline.loweredGraph())
let walker   = PipelineWalker(executor: EchoExecutor())

let result = try await walker.run(graph: graph) { event in
    print(event)            // observe step lifecycle, state updates, progress
}
print(try JSONDecoder().decode(String.self, from: result))
```

A `MockExecutor` ships so the package runs out of the box — model steps return an empty
placeholder and guardrails pass, which is enough to exercise graph shape in demos and tests.

## Documentation

- [Getting started](docs/getting-started.md) — install, your first pipeline, compile + walk.
- [Primitives](docs/primitives.md) — `Model`, `Guardrail`, `While`, `Group`, `ForEach`,
  `Summarize`, `ClientTask`, `@State`, and native control flow, with examples.
- [Executors](docs/executors.md) — the `Executor` seam in depth: `ExecutionValue` encoding,
  observation, errors and fallbacks.
- [Architecture](docs/architecture.md) — AST → compiler → walker, epochs and incremental
  re-execution, and the wire-format AST.

## License

Apache License 2.0 — © MacPaw Inc. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## A note on this repository

This repository is a **mirror**. The source of truth lives in MacPaw's monorepo and is
exported here one-directionally. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening
issues or pull requests.
