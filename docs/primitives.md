# Primitives

Every building block you compose inside a `@PipelineBuilder` body, with real signatures and
examples. All examples assume `import ComposablePipelines`.

- [The `Pipeline` protocol](#the-pipeline-protocol)
- [`@State` and bindings](#state)
- [`Model`](#model)
- [`Run` (client tasks)](#run)
- [`While`](#while)
- [`AgentLoop`](#agentloop) (a tool-calling loop with stop policies)
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

### Narrowing the tool list at run time

`.toolAllowlist(_ binding: Binding<[String]>)` records a slot holding tool names. Just before the call
the walker **filters** the step's declared tools down to those names, so the declared catalog is always
the upper bound — an unknown name is ignored:

```swift
Model<ModelTurn>.plan(systemPrompt: "…", tools: everyTool)
    .toolAllowlist($granted)      // slot holds e.g. ["get_weather"]
    .input { $instruction.get() }
```

Because narrowing is one-way, the slot is safe to fill from a model's own output — which is how a
`Delegate` hands each subagent only the tools its own subtask needs. Declaring the slot *is* the
narrowing statement, so it fails closed: an unwritten slot grants no tools rather than all of them, and a
slot that does not decode as `[String]` throws `ExecutionError.toolAllowlistDecodingFailed`.

---

## Classification

Two verbs, one per result shape, and a classifier value that says what to look for. `Classify` scores
the **whole text** in one bidirectional encoder pass and returns `LabelScores`; `Detect` labels
**ranges** of the text and returns `LabeledSpans`. Both take `text, using: classifier`, and one leaf,
`.classify(text:task:spec:)`, carries every task; the host serves each task *kind* with its own resource.

```swift
$gate.set { Classify(prompt, using: PromptRouter(lanes: ["answer from knowledge", "needs a tool"])) }
$pii.set  { Detect(draft, using: PIIDetector()) }
$lint.set { Detect(using: PolicyLinter(rules: ["Flag passwords.", "Flag file system paths."])) { $draft.get() } }
```

| Classifier | Kind | What comes back |
|---|---|---|
| `SequenceClassifier()` | `.sequence` | `LabelScores` over the checkpoint's own labels (no default checkpoint yet) |
| `ZeroShotSequenceClassifier(labels:)` | `.zeroShotSequence` | `LabelScores` aligned with `labels`, summing to 1; `topIndex` is the argmax |
| `TokenClassifier()` | `.token` | `LabeledSpans` with the checkpoint's own labels (`identity.person_name`, `contact.email`, …) |
| `ZeroShotTokenClassifier(labels:threshold:)` | `.zeroShotToken` | `LabeledSpans` per matched label scoring above `threshold`; `label` is the label text |

`PromptRouter(lanes:)`, `PIIDetector()` and `PolicyLinter(rules:)` are the generic classifiers spelled
for their use. Three things hold for every one of them:

- **`status` is the fallback.** With no backend for the task the result is `.unavailable`
  (`LabelScores.topIndex == nil`, `LabeledSpans.spans == []` under `status == .unavailable`), never an
  empty "nothing found". A pipeline must be able to tell "no detector" from "clean".
- **Labels come back with scores**, so a fixed-label result reads on its own; `topLabel` and
  `score(for:)` read by name. **Spans are UTF-16 offsets** into exactly the text the step received,
  with the matched substring in `text`; `span.range(in:)` converts back to `Range<String.Index>`.
- **`spec` is optional and usually absent.** The kind already names the model family; `nil` accepts
  any resource of that kind, so pipelines never carry model ids. A host with two models of one kind pins
  one with `spec: ModelSpecDescriptor`.

## Routing

Blocks that decide *where* a request goes, or *which* tools it should see, without spending a
generative turn on the question. Each lowers to its own AST leaf and is served by whatever backend the
host registers; with no backend, each degrades to a documented default rather than failing the run.

### `PromptRouter`

A classifier whose labels are routing lanes: `Classify(prompt, using: PromptRouter(lanes:))` scores the
prompt in one encoder pass and returns a `PromptRouteDecision` — a `LabelScores`, since `PromptRouter` is
a `ZeroShotSequenceClassifier` under a routing name.

```swift
$gate.set {
    Classify(using: PromptRouter(lanes: [
        "answer directly from knowledge",
        "needs live data, a tool, an action, or has several separate parts",
    ])) { $prompt.get() }
}
$delegates.set { $gate.map { $0.topIndex == 1 } }
```

`scores` is positionally aligned with `lanes`, so lane **order is the contract** for reading the
decision back. Three things are worth knowing:

- **Lane wording is load-bearing.** The score is a softmax over the lane text, so phrasing moves
  accuracy the way a system prompt does for a generative router. Treat lanes as tunable, not fixed.
- **`topIndex` is plain argmax; do not add a confidence threshold.** A narrow margin does not mean a
  wrong answer, so falling back to an expensive model when the router looks "unsure" pushes correct
  cheap decisions onto the slow path.
- **No backend yields `status == .unavailable`** (`topIndex == nil`), not lane 0 — a pipeline must be
  able to tell "no router available" from "the router chose the first lane", so it can take its own
  default branch.

Cost barely grows with lane count: one forward pass over one string, the lanes being prefix tokens.

### `RelevanceRanker`

Orders tools by embedding proximity to a query and returns the closest `topK`.

```swift
$ranked.set { RelevanceRanker(tools: dispatcher.descriptors, topK: 10) { $instruction.get() } }
$granted.set { $ranked.map { $0.rankedTools.map(\.descriptor.name) } }
```

`topK` is the only knob, deliberately. Scores are raw cosine similarities: comparable between
candidates of one query, but not calibrated across queries, so there is no meaningful absolute value
to cut against.

> **Breaking change.** `RelevanceRanker` previously took a `threshold: Float` and dropped candidates
> below it. That parameter is gone, along with the reranking pass whose calibrated probabilities gave
> it meaning. Remove the argument; use `topK` to bound the result. `PipelineGraphLeaf.relevanceRank`
> and `Executor.runRelevanceRank` lost the parameter with it — an external `Executor` conformer must
> update its signature, since the protocol extension's default would otherwise take over silently and
> answer `noBackend`.

### `DAGPlanner`

Produces a task graph for a query. Same seam, same no-backend fallback — an empty plan.

> **Removed.** `Router`, its `WorkflowRoute` result and the `.router` leaf are gone. It classified a
> query into three fixed cases using a trained two-layer classifier; `Classify(using: PromptRouter(lanes:))` (or its
> `PromptRouter` spelling) does the same job zero-shot, with labels the caller writes and no adapters to
> ship. Replace `Router(query, tools: …)` with lanes describing your cases, and read `topIndex` instead
> of a `WorkflowRoute`. `Executor.runRouter` went with it, and later `.promptRoute` /
> `Executor.runPromptRouting` folded into `.classify` / `Executor.runClassification`.

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

## `AgentLoop`

A `While` that owns a model turn: each iteration the model sees the conversation and the tools,
its tool calls are dispatched, and their results feed the next turn — until it answers without a
tool call, the turn budget runs out, or an attached **stop policy** ends it. The history is
compacted before it outgrows the context window.

```swift
let agent = AgentLoop(task: task, tools: tools, systemPrompt: prompt, maxTurns: 30)
    .finishTool()                 // registers `finish`; its call ends the run with its message
    .probe(watching: workspace)   // warn off a fixed point; warned again later forces the answer
    .answerOnLastTurn()           // the budget's last turn is a tool-free answer
let answer = try await PipelineRunner.run(agent, executor: executor)
```

| Modifier | Effect |
|---|---|
| `.finishTool()` | Adds `FinishTool` (unless a tool by that name is registered) and tells the model to call it when done; a call ends the run, its `message` is the answer. Applying it twice changes nothing. |
| `.probe(watching:escalates:)` | A `ProgressProbe` judges every call against the whole run — the same call, result and directory state seen before, or the same result three times despite edits — and the model is warned off it; with `escalates` (default) a warning in a later turn than the first makes the next turn a forced answer turn (warnings drawn by one turn count once: the model has not seen them yet). |
| `.answerOnLastTurn()` | The budget's last turn advertises no tools and asks for the answer, so a run never ends on a tool call. With `maxTurns` 1 that is the first turn, so the run does no work. |
| `.stopping(_:)` | Any `StopPolicy` — the extension point the others are built on. |

A **forced answer turn** sends the run so far as one rendered transcript under a reporting prompt,
with no tools and no prior turns, and ends the run on the answer it returns. Every line of tool
output in that transcript is prefixed with `| ` (a run of blank lines as one), and the prompt says
such lines are tool output, so a line in a file the agent read is marked as data rather than looking
like the agent's own words. The marks count against the transcript budget.

**Build it once** — create it, and apply its modifiers, outside lowering: as the root pipeline, or
as a stored property set in `init`. A loop created or modified inside a `body` traps: `@State` takes
a fresh slot id each time a pipeline value is created, and each modifier makes a new stop policy, so
the loop would start over every turn. Modifiers return copies, which keep the slots.

**One loop value per run.** The stop policies remember the run they watch (the probe's history,
whether it escalated), and nothing clears that when a run ends: a value run twice starts its second
run where the first stopped. Build a fresh loop for each run.

A `StopPolicy` can add a paragraph to the prompt, end the run with an answer after a turn, add
guidance after a tool call (`observe(_:)` gets an `ObservedCall`), or force the next turn to be an
answer turn — never edit the history or a tool's result. Several policies combine: any answer ends
the run, any forcing reason forces the turn, every warning is shown.

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
    Model<Bool, String>(instructions: "Is this on topic?", input: $message.get())   // nothing downstream starts until this clears
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
