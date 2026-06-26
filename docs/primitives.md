# Primitives

Every building block you compose inside a `@PipelineBuilder` body, with real signatures and
examples. All examples assume `import ComposablePipelines`.

- [The `Pipeline` protocol](#the-pipeline-protocol)
- [`@State` and bindings](#state)
- [`Model`](#model)
- [`Guardrail`](#guardrail)
- [`ClientTask`](#clienttask)
- [`While`](#while)
- [`ForEach`](#foreach)
- [`Group`](#group)
- [`Summarize`](#summarize)
- [`Just`](#just)
- [Native control flow](#native-control-flow)

---

## The `Pipeline` protocol

```swift
public protocol Pipeline {
    associatedtype Body: Pipeline
    associatedtype Output = Body.Output
    @PipelineBuilder var body: Self.Body { get }
}
```

Conform a `struct`, pin `Output`, and compose steps in `body`:

```swift
struct Greeting: Pipeline {
    typealias Output = String
    let name: String

    var body: some Pipeline {
        Model<String, String>(
            instructions: "Greet the user by name.",
            input: Just(value: name)
        )
    }
}
```

The `Output` of a builder block is the **last step's output**. Leaf steps such as `Model` and
`ClientTask` pin their own `Output` via generics.

Steps do **not** receive each other's typed results as inputs — dataflow goes through
[`@State`](#state).

---

## `@State`

Shared, typed context for a run. Each `@State` is a slot identified by a `UUID`; values flow
through the graph as JSON. The value type must be `Hashable & Sendable & Codable`.

```swift
@propertyWrapper
public struct State<Value: Hashable & Sendable & Codable> {
    public init(wrappedValue: Value, _ debugLabel: String? = nil)
    public var wrappedValue: Value
    public var projectedValue: Binding<Value>   // the `$state` accessor
}
```

Two ways to touch a slot:

- **Bare `state`** — reads the slot's value *as of the current epoch* while the body is being
  (re-)evaluated. Use it in Swift `if`/`switch` and string interpolation.
- **`$state` (the binding)** — graph-level operations the walker runs:

```swift
public struct Binding<Value> {
    public func set<P: Pipeline>(_ pipeline: P, writeKind: StateWriteKind = .commit) -> … where P.Output == Value
    public func set<P: Pipeline>(writeKind: StateWriteKind = .commit, @PipelineBuilder _ pipeline: () -> P) -> … where P.Output == Value
    public func set(_ value: Value, writeKind: StateWriteKind = .commit) -> …
    public func get() -> GetValue          // graph-level slot read
}
```

```swift
struct DocumentSummary: Pipeline {
    typealias Output = String
    let document: String

    @State var keyPoints = ""
    @State var draft = ""

    var body: some Pipeline {
        $keyPoints.set {                                   // write slot from a step
            Model<String, String>(
                instructions: "Extract the 5 most important points.",
                input: Just(value: document)
            )
        }
        $draft.set {                                       // read previous slot
            Model<String, String>(
                instructions: "Write a concise summary from these points.",
                input: $keyPoints.get()
            )
        }
        $draft.get()                                       // return slot value
    }
}
```

**Write kinds.** `.commit` (default) participates in incremental re-execution — after the
write, the body re-evaluates and the compiler can produce a new graph. `.draft` updates the
runner slot without triggering re-evaluation (useful for streaming partials).

> `@State` defaults are baked into the compiled graph, so you don't have to seed them through
> `initialSlots` when running.

---

## `Model`

A model inference step, generic over `<Input, Output>`. The walker hands the resolved
instructions/tools/input to your [`Executor`](executors.md).

Common initializers:

```swift
// instructions + input, both as constants or pipelines
public init<Instr: PipelineConvertible, InP: PipelineConvertible>(
    requirements: ModelSelectionRequirements? = nil,
    instructions: Instr,
    input: InP
) where InP.Output == Input

// input as a @PipelineBuilder closure (e.g. reading a slot)
public init<Instr: PipelineConvertible, InP: Pipeline>(
    requirements: ModelSelectionRequirements? = nil,
    instructions: Instr,
    @PipelineBuilder input: @escaping () -> InP
) where InP.Output == Input

// with tools
public init<Instr: PipelineConvertible, InP: PipelineConvertible>(
    requirements: ModelSelectionRequirements? = nil,
    instructions: Instr,
    tools: [any PipelineTool],
    input: InP
) where InP.Output == Input

// instructions only (Output == String, no input)
public init(requirements: ModelSelectionRequirements? = nil, instructions: String)
```

```swift
Model<String, String>(
    instructions: "Classify sentiment as positive, neutral, or negative.",
    input: $review.get()
)
```

### Model selection requirements

`requirements` is a *soft intent* the runtime resolves to a concrete model — not a model ID.
Selection happens in your executor, never in the authoring layer.

```swift
public struct ModelSelectionRequirements {
    public init(
        purpose: ModelPurpose? = nil,           // .chatCompletion, .textGeneration, .summarize, …
        backend: ModelBackend? = nil,           // .mlx or .custom("…")
        traits: ModelSelectionTraits = [],      // .quick, .reasoning, .localOnly, .lowMemory, …
        spec: ModelSpecDescriptor? = nil        // optional pin: sourceID / revision / files
    )
}
```

```swift
let fast = ModelSelectionRequirements(purpose: .textGeneration, traits: [.quick, .lowCost])

Model<String, String>(
    requirements: fast,
    instructions: "Summarize in one sentence.",
    input: $text.get()
)
```

`ModelSelectionTraits` is an `OptionSet`: `.quick`, `.localOnly`, `.instruct`, `.reasoning`,
`.streaming`, `.lowMemory`, `.lowCost`.

---

## `Guardrail`

Evaluates content-safety rules. By default it *gates* — the run does not proceed past it
unless the executor's `runGuardrail` returns `true`.

```swift
public init(rules: [GuardrailRule], gated: Bool = true)

public enum GuardrailRule: String { case politics, pii }
```

```swift
var body: some Pipeline {
    Guardrail(rules: [.politics, .pii])
    Model<String, String>(instructions: "Reply.", input: $message.get())
}
```

---

## `ClientTask`

Runs a closure on the host/client — the boundary for outside-world access (files, network,
secrets, UI). The graph records *that* a task runs (by `taskID`); the host decides *how*.

```swift
// input pipeline + async action
public init<InputPipeline: Pipeline>(
    taskID: UUID = UUID(),
    @PipelineBuilder input: @Sendable @escaping () -> InputPipeline,
    action: @escaping @Sendable (Input) async throws -> Output
) where InputPipeline.Output == Input

// input binding + async action
public init(taskID: UUID = UUID(), input: Binding<Input>,
            action: @escaping @Sendable (Input) async throws -> Output)

// no input
public init(taskID: UUID = UUID(),
            action: @escaping @Sendable () async throws -> Output) where Input == Never
```

```swift
$wordCount.set {
    ClientTask(input: $draft) { (text: String) async throws -> Int in
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
```

When you run a graph that contains client tasks, supply a `clientActionProvider` to
`PipelineWalker.run` so the walker can dispatch each `taskID` (see [Executors](executors.md)).

---

## `While`

Repeats its body while a Swift predicate holds. The condition is re-evaluated after each
committed state write — so the loop terminates through `@State`, not a hidden counter.

```swift
public init(condition: @Sendable @escaping () -> Bool,
            @PipelineBuilder body: @Sendable @escaping () -> Body)
```

```swift
@State var reply = ""

var body: some Pipeline {
    While(condition: { reply.isEmpty }) {
        $reply.set {
            ClientTask(input: $conversation) { raw in
                raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    $reply.get()
}
```

The walker caps re-execution depth at `PipelineWalker(maxReexecutionDepth:)` (default `200`).

---

## `ForEach`

Lowers a collection into a sequence of body emissions — one per element, in order.

```swift
public init(in data: @escaping @Sendable () -> C,
            @PipelineBuilder content: @escaping @Sendable (C.Element) -> Content)

public init(in data: C,
            @PipelineBuilder content: @escaping @Sendable (C.Element) -> Content)
```

```swift
ForEach(in: { chunks }) { chunk in
    $notes.set {
        Model<String, String>(instructions: "Note the key fact.", input: Just(value: chunk))
    }
}
```

An empty collection lowers to nothing. Pass values between iterations through shared `@State`
rather than relying on a typed element result.

---

## `Group`

Bundles steps into a unit the compiler treats atomically.

```swift
public init(sequential: Bool = true, gate: Bool = false,
            @PipelineBuilder _ content: () -> Content)
```

- `sequential` (default `true`): the group runs as one block; no internal parallelization.
- `gate` (default `false`): everything *after* the group waits for it to finish, regardless of
  slot dependencies — a barrier.

```swift
Group(gate: true) {
    Guardrail(rules: [.politics, .pii])   // nothing downstream starts until this clears
}
```

---

## `Summarize`

Condenses the text in a slot to a token budget.

```swift
public init(text: Binding<String>, maxTokens: Int)
```

```swift
$summary.set {
    Summarize(text: $draft, maxTokens: 512)
}
```

---

## `Just`

Lifts a constant value into a pipeline — most often as a `Model`/`ClientTask` input.

```swift
public init(value: Output)
```

```swift
Model<String, String>(instructions: "Echo.", input: Just(value: "hello"))
```

---

## Native control flow

`@PipelineBuilder` supports Swift `if`/`else`, `if` without `else`, and `#available`. Branch
conditions read state via the bare `state` accessor; on a state change the body re-evaluates
and the compiler emits an updated graph.

```swift
struct Moderate: Pipeline {
    typealias Output = String
    @State var input: String
    @State var severity = ""
    @State var explanation = ""

    var body: some Pipeline {
        Guardrail(rules: [.politics, .pii])
        $severity.set {
            Model<String, String>(
                instructions: "Classify severity as safe, medium, or high.",
                input: $input.get()
            )
        }
        if severity == "safe" {
            $explanation.set("Content is safe. No action needed.")
        } else {
            $explanation.set {
                Model<String, String>(
                    instructions: "Write a brief moderation explanation for \(severity).",
                    input: $input.get()
                )
            }
        }
        $explanation.get()
    }
}
```

Each branch must itself be a `Pipeline`. See [Architecture](architecture.md) for how
re-evaluation and prefix-skip keep this from re-running completed work.
