# Architecture

Composable Pipelines is four layers. Each depends only on the one below, and the boundary
between them is a plain value you can serialize.

```
@PipelineBuilder        PipelineCompiler         PipelineWalker          Executor
Swift DSL code          .compile(_:)             .run(_:)                runModel / runGuardrail
     │                       │                        │                       │
     ▼                       ▼                        ▼                       ▼
PipelineGraph ─────▶ PipelineExecutionGraph ──▶ walk + epoch ───────▶ host-supplied execution
(Codable AST)        (sequential/parallel)      re-execution            → ExecutionValue
```

| Layer | Product | Role |
| --- | --- | --- |
| **DSL** | `PipelineDSL` | Author intent with `@PipelineBuilder`, `@State`, primitives. Lowers to the AST. |
| **AST** | `PipelineAST` | The `Codable` `PipelineGraph` — the universal exchange format. Foundation-only. |
| **Compiler** | `PipelineCompiler` | Lowers the AST to an optimized `PipelineExecutionGraph` (dependency analysis, slot-hazard ordering, gates/barriers, topological batching). |
| **Walker** | `ExecutionEngine` | `PipelineWalker` follows the graph, drives state and incremental re-execution, is observable, and delegates each operation to an `Executor`. |

## The AST is the wire format

A pipeline lowers to a `PipelineGraph` — a `Codable` value with no behavior. That's the
headline property: **encode it on one machine, decode and run it on another.**

```swift
let graph = pipeline.loweredGraph()
let bytes = try JSONEncoder().encode(graph)        // send over the wire
// …on a backend…
let received = try JSONDecoder().decode(PipelineGraph.self, from: bytes)
let plan = PipelineCompiler().compile(received)
```

Because the AST is the boundary, the authoring app and the executing runtime need not be the
same process, language host, or device. The DSL is *runtime-agnostic* — the same pipeline runs
against any `Executor`.

## Compilation

`PipelineCompiler.compile(_:)` turns the lowered AST into a `PipelineExecutionGraph`: it
analyzes slot reads/writes, orders steps to respect hazards, builds gates and barriers (e.g.
from `Group(gate:)`), and groups independent work into parallel batches.

```swift
public struct PipelineCompiler {
    public struct Optimizations: OptionSet {
        public static let parallelize: Optimizations   // batch independent steps
        public static let `default`: Optimizations     // [.parallelize]
        public static let none: Optimizations          // strict sequential
    }
    public init(optimizations: Optimizations = .default, logger: PipelineLog = .none)
    public func compile(_ ast: PipelineGraph) -> PipelineExecutionGraph
}
```

The result is itself `Codable` — "the path" anyone can walk.

## Walking and incremental re-execution

`PipelineWalker.run(...)` follows the execution graph and, for each operation, either runs it
through the `Executor`/`clientActionProvider` or serves a cached value. Two ideas make
re-execution cheap and predictable:

**Epochs.** Every committed `@State` write advances a monotonic epoch. While the body
re-evaluates, bare `state` reads resolve *as of the current epoch* — a recompile step, not a
reactive recompute. This prevents feedback loops (e.g. a counter that would otherwise
increment every time the body re-emits).

**Prefix skip.** Native `if`/`switch` in the body means a state change can cause the body to be
re-emitted and recompiled. The walker treats already-completed leading top-level steps as
no-ops on the next pass — matched by walk ordinal — so previous lines don't re-run just because
the body was re-emitted. A `$state.set(...)` that already ran is skipped on later passes; the
slot already holds its value.

This is what lets `While` and conditional bodies work: the loop body re-evaluates against fresh
state each pass, while completed work upstream is not repeated.

```swift
public final class PipelineWalker {
    public init(executor: any Executor,
                maxReexecutionDepth: Int = 200,
                logger: PipelineLog = .none,
                observer: (any PipelineRunObserver)? = nil)

    public func run(
        graph: PipelineExecutionGraph,
        clientActionProvider: (@Sendable (UUID, ExecutionValue) async throws -> ExecutionValue)? = nil,
        contextProviders: [UUID: any ContextItemsProvider] = [:],
        initialSlots: [UUID: ExecutionValue] = [:],
        onCommittedBatch: (@Sendable ([StateUpdate]) -> Void)? = nil,
        graphProvider: (@Sendable (ExecutionCursor) -> ReexecutionGraph?)? = nil,
        observingExecution: (@Sendable (ExecutionEvent) -> Void)? = nil
    ) async throws -> ExecutionValue
}
```

`maxReexecutionDepth` bounds the re-execution loop (default `200`). `graphProvider` is the
reactive hook: after a commit flush it can return a replacement graph for the next pass.

## Design principles

1. **Layered independence.** Each layer depends only on the one below. The AST is the universal
   exchange format; execution depends on the compiler, not the DSL.
2. **Data as `Data`.** State and operation I/O flow as JSON `Data` (`ExecutionValue`); typed
   `@State<Value>` decodes with full type knowledge. No double-encoding.
3. **Workflow steps over reactive formulas.** Body re-evaluation is a pure recompile.
   `$state.set` writes once and is prefix-skipped thereafter; bare `state` reads are
   epoch-stable. The result is deterministic re-execution without hidden feedback loops.
4. **The runtime is yours.** Open source ends at the walker. *Executing* an operation — model
   selection, backends, resource lifecycle — lives behind the `Executor` seam, which you own.
