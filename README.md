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
- **Dependency-light.** Resolves on Foundation and swift-syntax — no
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
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        let system = arguments.systemPrompt
        let text: String
        if case .string(let message)? = arguments.message { text = message } else { text = "" }
        return try JSONEncoder().encode("[\(system)] \(text)")   // call a real model here
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

### Try it against a real model

A ready-made `OpenAIChatExecutor` (Foundation-only) talks to any OpenAI-compatible endpoint.
The bundled `cp-demo` executable runs a three-step **draft → revise → polish** pipeline on a
topic you pass as an argument: it compiles the pipeline, walks it through the executor, streams
the step/state events to stderr, and prints the finished paragraph to stdout.

It is configured entirely through environment variables:

| Variable | Required | Default | Notes |
| --- | --- | --- | --- |
| `OPENAI_API_KEY` | yes | — | Any non-empty value. Local servers usually ignore it — pass a dummy like `x`. |
| `OPENAI_BASE_URL` | no | `https://api.openai.com/v1` | Point at any OpenAI-compatible endpoint. |
| `OPENAI_MODEL` | no | `gpt-4o-mini` | Model id the endpoint serves. |

**Against OpenAI:**

```bash
export OPENAI_API_KEY=sk-...
swift run cp-demo "Swift result builders"
```

**Against a local server** (Ollama, LM Studio, mlx-lm, etc.) — these typically need no token, so
pass a throwaway key to satisfy the required check:

```bash
OPENAI_API_KEY=x \
OPENAI_BASE_URL=http://localhost:1977/v1 \
OPENAI_MODEL=your-local-model \
swift run cp-demo "Swift result builders"
```

> **Reasoning models:** the demo requests a generous `maxTokens` per step because reasoning
> models spend tokens thinking before they emit any reply — a small token budget can truncate
> them (`finish_reason: "length"`) before any content is produced. Local inference can also be
> slow, so the executor uses a long request timeout. If a step returns no text, raise the
> server's token limit.

With no `OPENAI_API_KEY` set, `cp-demo` prints a hint and exits non-zero — handy for confirming
the wiring without making a network call.

## Documentation

- [Getting started](docs/getting-started.md) — install, your first pipeline, compile + walk.
- [Primitives](docs/primitives.md) — `Model`, `Guardrail`, `While`, `Group`, `ForEach`,
  `Summarize`, `ClientTask`, `@State`, and native control flow, with examples.
- [Executors](docs/executors.md) — the `Executor` seam in depth: `ExecutionValue` encoding,
  observation, errors and fallbacks.
- [Architecture](docs/architecture.md) — AST → compiler → walker, epochs and incremental
  re-execution, and the wire-format AST.
- [Examples/](Examples/) — runnable reference pipelines: map-reduce (`ForEach`), retrieval (`From`),
  cost-aware model-tier routing (`requirements:` + early `return`), a self-healing retry loop, and a
  tool-calling agent loop (`ModelTurn` + `ClientTask`).

## License

Apache License 2.0 — © MacPaw Inc. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## A note on this repository

This repository is a **mirror**. The source of truth lives in MacPaw's monorepo and is
exported here one-directionally. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening
issues or pull requests.
