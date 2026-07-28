# Executors

The **walker orchestrates; the executor executes.** `PipelineWalker` follows the compiled
graph — ordering, parallel batching, state, incremental re-execution — and for every
model/guardrail step it calls out to an `Executor` you provide. That seam is where you plug in
your runtime: a local model, a hosted API, a remote service, anything.

- [The protocol](#the-protocol)
- [ExecutionValue encoding](#executionvalue-encoding)
- [A real executor](#a-real-executor)
- [Running with client tasks](#running-with-client-tasks)
- [Observing a run](#observing-a-run)
- [Errors and fallbacks](#errors-and-fallbacks)
- [MockExecutor](#mockexecutor)

---

## The protocol

```swift
public protocol Executor: Sendable {
    func runModel(
        instructions: ExecutionValue,
        tools: ExecutionValue,
        input: ExecutionValue,
        outputTypeName: String,
        requirements: ModelSelectionRequirements?
    ) async throws -> ExecutionValue

    func runGuardrail(rules: [GuardrailRule]) async throws -> ExecutionValue
}
```

- `runModel` receives the already-resolved instructions, tools, and input for one `Model`
  step. `outputTypeName` is the name of the step's declared `Output` (e.g. `"String"`);
  `requirements` is the soft model-selection intent. Return the encoded result.
- `runGuardrail` evaluates the rules for one `Guardrail` step. Return a JSON-encoded `Bool`
  (`true` == passes / proceed).

---

## ExecutionValue encoding

`ExecutionValue` is a typealias for `Data` — UTF-8 JSON bytes:

```swift
public typealias ExecutionValue = Data
```

Everything flowing through the graph is JSON-encoded. Decode inputs with the type you expect,
encode outputs the same way:

```swift
let text   = try JSONDecoder().decode(String.self, from: input)
let result = try JSONEncoder().encode("…answer…")
```

The client-side `@State<Value>` decodes results with full type knowledge, so there's no
double-encoding — keep your executor's encode/decode symmetric with the slot types your
pipeline uses.

---

## A real executor

A minimal executor that calls an async model API and always passes guardrails:

```swift
struct APIExecutor: Executor {
    let client: MyModelClient

    func runModel(
        instructions: ExecutionValue, tools: ExecutionValue, input: ExecutionValue,
        outputTypeName: String, requirements: ModelSelectionRequirements?
    ) async throws -> ExecutionValue {
        let system = try JSONDecoder().decode(String.self, from: instructions)
        let user   = try JSONDecoder().decode(String.self, from: input)

        // Map the soft requirements to one of your models.
        let model = client.pick(for: requirements)
        let answer = try await client.complete(system: system, user: user, model: model)

        return try JSONEncoder().encode(answer)
    }

    func runGuardrail(rules: [GuardrailRule]) async throws -> ExecutionValue {
        let passes = try await client.checkSafety(rules.map(\.rawValue))
        return try JSONEncoder().encode(passes)
    }
}

let walker = PipelineWalker(executor: APIExecutor(client: myClient))
let result = try await walker.run(graph: graph)
```

---

## Running with client tasks

`Run` (client task) steps don't go through the executor — the walker resolves them through a
`clientActionProvider`. The DSL captures each task's closure when you lower the pipeline; wire
those captured actions into the run:

```swift
let lowered = pipeline.lowered()                       // graph + captured client actions
let graph   = PipelineCompiler().compile(lowered.graph)

let result = try await walker.run(
    graph: graph,
    clientActionProvider: PipelineWalker.clientActionProvider(
        from: lowered.clientActions.mapValues { action in
            // adapt (Data) -> Data closures into the walker's ExecutionValue form
            { @Sendable (value: ExecutionValue) in try await action(value) }
        }
    )
)
```

If you only need the graph (no client tasks), `pipeline.loweredGraph()` is the shortcut used
elsewhere in these docs.

---

## Observing a run

`run(observingExecution:)` streams `ExecutionEvent`s as the walk proceeds:

```swift
let result = try await walker.run(graph: graph) { event in
    switch event {
    case .stepStarted(let s):                 log("▶︎ \(s.prettyLabel)")
    case .stepCompleted(let s, let preview, let ns):
                                              log("✓ \(s.prettyLabel) → \(preview) (\(ns) ns)")
    case .stepSkipped(let s):                 log("↩︎ \(s.prettyLabel) (cached)")
    case .stepFailed(let s, let error, _):    log("✗ \(s.prettyLabel): \(error)")
    case .stateUpdated(let u):                log("· slot \(u.slotID) written")
    case .parallelGroupStarted(let n):        log("⇉ \(n) branches")
    case .executionCompleted:                 log("done")
    default: break
    }
}
```

Helpers fold the step-lifecycle cases:

```swift
var statuses: [UUID: TaskExecutionStatus] = [:]
let result = try await walker.run(graph: graph) { event in
    if let step = event.stepInfo, let status = event.taskStatus {
        statuses[step.taskID] = status        // live snapshot of every task
    }
}
```

`StepInfo` carries `taskID`, `operationLabel` (`"model"`, `"guardrail"`, `"stateSet"`, …),
`prettyLabel` (`"$severity.set"`, `"model → String"`), and `slotID` for state operations.

For run-level telemetry, pass a `PipelineRunObserver` to `PipelineWalker(observer:)`.

---

## Errors and fallbacks

Throw `ExecutorError.noBackend` when no model/guardrail can satisfy a request. The walker
treats it as a soft miss and applies a fallback (an empty result for a model, pass-through for
a guardrail) rather than aborting the run — which is exactly how `MockExecutor` behaves. Any
other error you throw propagates: the walker emits `.stepFailed` and the `run` call rethrows.

---

## MockExecutor

Ships with the package so a pipeline runs end to end with no real backend:

```swift
public struct MockExecutor: Executor {
    public init()
    // runModel / runGuardrail throw ExecutorError.noBackend → walker applies fallbacks
}
```

```swift
let walker = PipelineWalker(executor: MockExecutor())
let result = try await walker.run(graph: graph)   // model steps return "", guardrails pass
```

Use it to exercise graph shape, ordering, and observation in demos and tests — not for real
output.
