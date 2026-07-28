# Primitives

Every building block you compose inside a `@PipelineBuilder` body, with real signatures and
examples. All examples assume `import ComposablePipelines`.

- [The `Pipeline` protocol](#the-pipeline-protocol)
- [`@State` and bindings](#state)
- [`Model`](#model)
- [`Guardrail`](#guardrail)
- [`Run` (client tasks)](#run)
- [`While`](#while)
- [`ForEach`](#foreach)
- [`Group`](#group) (and `Concurrent` / `Barrier`)
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
`Run` pin their own `Output` via generics.

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

**`.assign(to:)` vs `.set { }`.** `producer.assign(to: $slot)` is the producer-first spelling of
the *value* form `$slot.set(producer)`. It's the right tool when the producer's dependencies are
**graph-encoded** — `.input { $other }`, `Run`, `$x.map { … }`, constants, or plain `let`s.
It **cannot** capture a bare `@State` read made *while building* the producer (e.g.
`Model("…").message(keyPoints)` or a prompt interpolating `\(severity)`), because a postfix
modifier can't snapshot reads before the producer was constructed. For those, use the closure
form `$slot.set { producer }`, which snapshots reads up front and records the dependency:

```swift
// graph-encoded dependency → .assign is fine
Model<String>("Summarize.").input { $keyPoints }.assign(to: $draft)

// producer bakes a bare @State read → use the closure form so the dependency is captured
$draft.set { Model<String>("Summarize \(topicTone) style.").message(keyPoints) }
```

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

Rules read as a variadic list on `GuardrailClassification` (the `Bool`-producing classifier)
and on `GateGuardrail` (a bare gate over one input), so you skip the `rules:` label and the
array brackets:

```swift
GuardrailClassification(.politics, .pii) { $message.get() }   // -> Bool
GateGuardrail(.politics, .pii) { $message.get() }             // gate; proceeds only if it passes
```

---

## `Run`

Runs a closure on the host/client — the boundary for outside-world access (files, network,
secrets, UI). The graph records *that* a task runs (by `taskID`); the host decides *how*.
`ClientTask` is the previous name and remains available as a typealias.

```swift
// one binding in — Input from the binding, Output from the closure
public init(id: String? = nil, _ input: Binding<Input>,
            action: @escaping @Sendable (Input) async throws -> Output)

// two / three bindings in — the input lowers to a `combine` leaf and arrives together
public init<A, B>(id: String? = nil, _ first: Binding<A>, _ second: Binding<B>,
                  action: @escaping @Sendable (A, B) async throws -> Output)
    where Input == Combined2<A, B>

// no input
public init(taskID: UUID = UUID(),
            action: @escaping @Sendable () async throws -> Output) where Input == Never
public init(id: String,
            action: @escaping @Sendable () async throws -> Output) where Input == Never

// input pipeline + async action (general form)
public init<InputPipeline: Pipeline>(
    taskID: UUID = UUID(),
    @PipelineBuilder input: @Sendable @escaping () -> InputPipeline,
    action: @escaping @Sendable (Input) async throws -> Output
) where InputPipeline.Output == Input
```

```swift
Run($draft) { text in
    text.split(whereSeparator: \.isWhitespace).count
}
.assign(to: $wordCount)

Run($draft, $tone) { draft, tone in applyTone(tone, to: draft) }
    .assign(to: $draft)

Run { try await fetchUserLocale() }
    .assign(to: $locale)
```

Pure single-slot transforms read better as `Binding.map` — it lowers to the same
`clientAction` leaf:

```swift
$draft.map { $0.count }.assign(to: $wordCount)
$draft.map(\.wordCount).assign(to: $summaryLength)
```

**Identity.** Closure captures never cross the wire — only the `taskID` does. The default
`taskID` is a fresh `UUID` per value, which is fine for local runs (the lowering registers the
closure each time). When a graph is *encoded and executed remotely*, give the task a stable
string `id:`; both sides derive the same UUID via `UUID(stableTaskName:)`, so the host's
`clientActionProvider` can dispatch it across lowerings and launches.

When you run a graph that contains client tasks, supply a `clientActionProvider` to
`PipelineWalker.run` so the walker can dispatch each `taskID` (see [Executors](executors.md)).

---

## `While`

Repeats its body while a Swift predicate holds. The condition is re-evaluated after each
committed state write — so the loop terminates through `@State`, not a hidden counter.

```swift
public init(condition: @Sendable @escaping () -> Bool,
            @PipelineBuilder body: @Sendable @escaping () -> Body)

// autoclosure spelling — the condition expression is re-evaluated on every emission
public init(_ condition: @autoclosure @Sendable @escaping () -> Bool,
            @PipelineBuilder body: @Sendable @escaping () -> Body)
```

```swift
@State var reply = ""

var body: some Pipeline {
    While(reply.isEmpty) {                     // autoclosure; same as condition: { reply.isEmpty }
        $conversation.map { raw in
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .assign(to: $reply)
    }
    $reply                                     // bare binding == $reply.get()
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

// SwiftUI-parity spellings — drop the `in:` label
public init(_ data: C, @PipelineBuilder content: @escaping @Sendable (C.Element) -> Content)
public init(_ data: @escaping @Sendable () -> C,
            @PipelineBuilder content: @escaping @Sendable (C.Element) -> Content)
```

```swift
ForEach(chunks) { chunk in                     // no `in:` label
    Run { noteKeyFact(in: chunk) }.assign(to: $notes)
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

For the two non-default combinations, prefer the named spellings — they read at the call site
where `Group(sequential:gate:)`'s booleans don't:

```swift
Concurrent { … }        // == Group(sequential: false) — steps may run in parallel
Barrier { … }           // == Group(gate: true) — a barrier; downstream waits
Group { … }.gated()     // == Group(gate: true) — modifier form

Barrier {
    GateGuardrail(.politics, .pii) { $message.get() }   // nothing downstream starts until this clears
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

Lifts a constant value into a pipeline — most often as a `Model`/`Run` input.

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
