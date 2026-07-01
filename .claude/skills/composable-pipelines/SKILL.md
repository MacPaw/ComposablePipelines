---
name: composable-pipelines
description: Build AI pipelines with the ComposablePipelines Swift package — author a declarative Pipeline (result-builder DSL + @State), compile it to a graph, and run it through an Executor. Use when writing or debugging ComposablePipelines code: Pipeline/Model/Guardrail/While/ForEach/ClientTask, @State data flow, the Executor seam, reactive While/branching, tool-calling agent loops, or when a file imports ComposablePipelines / PipelineDSL / PipelineCompiler / ExecutionEngine.
---

# Composable Pipelines

A runtime-agnostic stack for AI pipelines in Swift: a declarative **DSL** lowers to a `Codable`
**AST**, a **compiler** emits an execution graph, and an observable **walker** runs it — while an
`Executor` you supply decides what "run a model" means.

## Quick start

```swift
import ComposablePipelines

struct Summary: Pipeline {
    typealias Output = String
    let document: String

    @State var keyPoints = ""
    @State var summary = ""

    var body: some Pipeline {
        $keyPoints.set {                                    // step 1 → slot
            Model<String>().systemPrompt("Extract the 5 key points.").message(document)
        }
        $summary.set {                                      // step 2 reads step 1
            Model<String>().systemPrompt("Summarize from these points.").input { $keyPoints.get() }
        }
        $summary.get()                                      // pipeline output
    }
}

// Run it (linear flow): compile → walk.
let graph  = PipelineCompiler().compile(pipeline.loweredGraph())
let result = try await PipelineWalker(executor: MyExecutor()).run(graph: graph) { event in print(event) }
let text   = try JSONDecoder().decode(String.self, from: result)   // ExecutionValue == Data (JSON)
```

## Authoring cheatsheet

- **Pipeline**: `struct X: Pipeline { typealias Output = T; @State var … ; var body: some Pipeline { … } }`.
  The graph is inferred from the `@State` slots each step reads/writes — never wired by hand.
- **State**: `@State var s = ""` → write with `$s.set { <pipeline> }` or `$s.set(value)`; read with
  `$s.get()`. End `body` with the output slot's `.get()`.
- **Model** (output-only generic): `Model<Output>()` then chain `.systemPrompt(_)`,
  `.input { $slot.get() }` **or** `.message(staticValue)`, and optionally `.tools([…])`,
  `.temperature(_)`, `.maxTokens(_)`, `.requirements(ModelSelectionRequirements(traits: […]))`.
- **Primitives**: `Guardrail(input, rules:allowed:blocked:)`, `While(condition:) { … }`,
  `Group { … }`, `ForEach(in: xs) { x in … }`, `Summarize(text: $slot, maxTokens:)`,
  `ClientTask(input: $slot) { value in … }`, `From(provider, query: $slot)`, `Self.return(value)`.
- **Control flow**: use native `if` / `switch` on produced state (e.g. `if verdict == "trivial"`).

## Running a pipeline

- **Linear flow** (sequential, `ForEach`, retrieval, runtime `.get()`): compile once, then
  `PipelineWalker(executor:).run(graph:)`.
- **Reactive flow** (a `While` loop, or `if`/`switch` that branch on a *produced* value): use
  `PipelineRunner.run(pipeline, executor:)`. It re-lowers and recompiles after each committed write
  so the condition/branch re-reads state. A single `walker.run` is **not** enough for these.

## The Executor seam

The walker never calls a model itself. Implement one method:

```swift
struct MyExecutor: Executor {
    func runModel(config: ModelConfig, arguments: ModelArguments,
                  onDelta: (@Sendable (String) -> Void)?) async throws -> ExecutionValue {
        let system = arguments.systemPrompt                         // String
        let user: String; if case .string(let s)? = arguments.message { user = s } else { user = "" }
        // … call your model … then encode the output as JSON Data:
        return try JSONEncoder().encode(reply)                       // or ModelTurn for tool turns
    }
}
```

`MockExecutor` ships for tests; `OpenAIChatExecutor` (Foundation-only) talks to any
OpenAI-compatible endpoint (local or remote).

## Tool-calling agents

A model step whose output is `ModelTurn` can request tools; you dispatch them and loop:

```swift
While(condition: { reply.isEmpty && turns < maxTurns }) {
    $lastTurn.set { Model<ModelTurn>().tools(tools.map(\.descriptor)).systemPrompt(prompt).input { $transcript.get() } }
    $transcript.set {
        ClientTask(input: $lastTurn) { turn in
            guard let calls = turn.toolCalls, !calls.isEmpty else { return transcript }
            var t = transcript
            for call in calls {
                let out = try await ToolRegistry(tools).executeJSON(toolName: call.name, inputJSON: Data(call.arguments.utf8))
                t += "\n[\(call.name)] " + String(decoding: out, as: UTF8.self)
            }
            return t
        }
    }
    $reply.set { ClientTask(input: $lastTurn) { $0.toolCalls?.isEmpty == false ? "" : ($0.reply ?? "") } }
    $turns.set { ClientTask(input: $turns) { $0 + 1 } }
}
$reply.get()
```

Tools are `ModelTool`s (static `name`/`description`/`inputSchema` + `func call(_:) -> Output`),
registered in a `ToolRegistry`. Drive tool/agent loops with `PipelineRunner.run`.

## Pitfalls (read before writing code)

- **`Model` takes one generic — the output.** It's `Model<Output>().systemPrompt(…).input { … }`,
  **not** `Model<Input, Output>(instructions:input:)` (that API does not exist).
- **Never read `@State` inside a `ClientTask` closure.** Thread state in via the typed input:
  `ClientTask(input: $slot) { value in … }`. Reading `@State` in the closure is disallowed.
- **`While` / value-dependent branching need `PipelineRunner.run`**, not a bare `walker.run` — they
  require reactive re-lowering.
- **`ExecutionValue` is JSON `Data`.** Decode results (`JSONDecoder().decode(T.self, from:)`) and
  encode executor outputs (`JSONEncoder().encode(_)`).
- **A turn can carry a preamble *and* tool calls.** In an agent loop, keep looping while there are
  tool calls; only a tool-free turn is the final answer.

## Reference

Deep docs live in the package: [`docs/examples.md`](../../../docs/examples.md) (worked pipelines
with code), `docs/primitives.md`, `docs/executors.md`, `docs/architecture.md`, and the top-level
`README.md`. The runnable examples in `Examples/` are execution-tested — copy from them.
