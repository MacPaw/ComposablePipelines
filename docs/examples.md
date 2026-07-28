# Example pipelines

The pipelines in [`Examples/`](../Examples/) are runnable reference implementations — each a single,
self-contained file. They are **built and execution-tested as part of the package**, so they never
drift from the current API.

The snippets below are **shortened** (prompts trimmed, some scaffolding elided) to highlight the
shape; click each heading for the full, tested source. They're ordered from the simplest sequential
flow to a full tool-calling agent loop.

## Sequential state flow

### [`DocumentSummaryPipeline`](../Examples/DocumentSummaryPipeline.swift)
Each step reads the slot the previous one wrote — a straight data-dependency chain. `Summarize`
gives length control; `Group` scopes a stage.

```swift
struct DocumentSummaryPipeline: Pipeline {
    typealias Output = String
    let document: String

    @State var keyPoints = ""
    @State var draft = ""
    @State var summary = ""

    var body: some Pipeline {
        Model<String>("Extract the 5 key points.").message(document).assign(to: $keyPoints)
        Model<String>("Summarize from these points.").input { $keyPoints }.assign(to: $draft)
        Group { Summarize(text: $draft, maxTokens: 512).assign(to: $summary) }
    }
}
```

## Parallel fan-out and merge

### [`ContentWriterPipeline`](../Examples/ContentWriterPipeline.swift)
The three critiques read `draft` but not each other, so the compiler runs them **in parallel**; the
rewrite depends on all three and waits for them. (The full source also gates the topic with a
`Guardrail`.)

```swift
Model<String>("Write a short article on the topic.").input { $topic }.assign(to: $draft)

// No data dependency between these three → they run concurrently.
Model<String>("Review grammar. Be concise.").input { $draft }.assign(to: $grammarNotes)
Model<String>("Review tone & style. Be concise.").input { $draft }.assign(to: $styleNotes)
Model<String>("Flag unsupported claims. Be concise.").input { $draft }.assign(to: $factNotes)

// The prompt bakes bare `grammarNotes`/`styleNotes`/`factNotes` (@State) at lowering, so use the
// closure `set { }` form — it captures those reads as dependencies; `.assign` (value form) can't.
$finalDraft.set {
    Model<String> {
        "Rewrite applying:"
        "Grammar: \(grammarNotes)"
        "Style: \(styleNotes)"
        "Facts: \(factNotes)"
    }
    .input { $draft }
}
```

## Data-driven iteration (map-reduce)

### [`BatchSummaryPipeline`](../Examples/BatchSummaryPipeline.swift)
`ForEach` unrolls its body once per element **at lowering**, so the step count follows the data. A
shared slot read with `.get()` accumulates across iterations; a final step reduces it.

```swift
struct BatchSummaryPipeline: Pipeline {
    typealias Output = String
    let documents: [String]

    @State var notes = ""
    @State var digest = ""

    var body: some Pipeline {
        ForEach(documents) { document in                           // one step per element
            // `document` is the loop element (a `let`), not @State — safe to assign.
            Model<String>("Summarize in one line, append to the notes:\n\(document)")
                .input { $notes }                                  // reads what the prior iteration committed
                .assign(to: $notes)
        }
        Model<String>("Two-sentence digest of these notes.").input { $notes }.assign(to: $digest)
    }
}
```

## Branching on model output

### [`CodeReviewPipeline`](../Examples/CodeReviewPipeline.swift)
Request models by capability, not name (`requirements:`); branch on the produced verdict; and
short-circuit with `Self.return` to skip the expensive path.

```swift
// cheap triage, quick local model
Model<String>(
    "Triage: reply 'trivial' or 'needs-review'.",
    requirements: ModelSelectionRequirements(traits: [.quick, .localOnly])
)
.input { $diff }
.assign(to: $verdict)
if verdict == "trivial" {                                          // reactive branch on the result
    Self.return("LGTM — trivial change.")                          // skip the expensive model
}
// escalate to a reasoning model
Model<String>(
    "Thorough review; list concerns.",
    requirements: ModelSelectionRequirements(traits: [.reasoning])
)
.input { $diff }
.assign(to: $review)
$review
```

### [`ContentModerationPipeline`](../Examples/ContentModerationPipeline.swift)
A `Guardrail` gates the input; `if`/`else` on the classified severity picks the path.

```swift
Guardrail(input, rules: [.politics, .pii], allowed: {
    Model<String>("Classify severity…").input { $input }.assign(to: $severity)
    if severity == "safe" {
        $explanation.set("Content is safe. No action needed.")
    } else {
        Model<String>("Explain the violation…").input { $input }.assign(to: $explanation)
    }
}, blocked: {
    Just(value: "I can't help with that — it conflicts with the safety policy.")
})
```

## Routing and composition

### [`CustomerSupportPipeline`](../Examples/CustomerSupportPipeline.swift)
Classify intent, then `switch` to specialized handling per category.

```swift
Model<String>("Classify: billing, technical, feedback, general").input { $message }.assign(to: $intent)
switch intent {
case "billing":   Model<String>("Draft a billing response.").input { $message }.assign(to: $reply)
case "technical": Model<String>("Write troubleshooting steps.").input { $message }.assign(to: $reply)
default:          Model<String>("Provide a helpful response.").input { $message }.assign(to: $reply)
}
$reply
```

## Retrieval-augmented generation

### [`KnowledgeBaseQAPipeline`](../Examples/KnowledgeBaseQAPipeline.swift)
`From` pulls `[ContextItem]` from any `ContextItemsProvider` (a vector store, a memory service, or a
fixture), then the answer is grounded only in what was retrieved.

```swift
struct KnowledgeBaseQAPipeline: Pipeline {
    typealias Output = String
    let knowledgeBase: any ContextItemsProvider

    @State var question: String
    @State var context: [ContextItem] = []
    @State var answer = ""

    var body: some Pipeline {
        From(knowledgeBase, query: $question).assign(to: $context)         // retrieve
        // answer from context only
        Model<String>("Answer using only the provided context; else say you don't know.")
            .input { $context }
            .assign(to: $answer)
    }
}
```

## Loops, retries, and agents

### [`SelfHealingExtractionPipeline`](../Examples/SelfHealingExtractionPipeline.swift)
A `While` retry loop over ordinary `@State`: ask for JSON, validate in plain Swift via `Run`,
and fold the previous error back into the next prompt until it's valid or attempts run out.

```swift
While(!valid && attempts < maxAttempts) {
    // Prompt folds bare `lastError` (@State) into each retry → closure `set { }` form required.
    $candidate.set {
        Model<String>("Extract {\"name\",\"age\"} as JSON. \(lastError.isEmpty ? "" : "Previous error: \(lastError)")")
            .message(text)
    }
    $candidate.map { Self.isValidPersonJSON($0) }.assign(to: $valid)
    $candidate.map { Self.isValidPersonJSON($0) ? "" : "expected name and age" }.assign(to: $lastError)
    $attempts.map { $0 + 1 }.assign(to: $attempts)
}
$candidate
```

### [`ResearchAssistantPipeline`](../Examples/ResearchAssistantPipeline.swift)
A tool-calling agent loop: each turn the model calls tools or answers; tool results feed back into
the transcript until it returns a final reply.

```swift
While(reply.isEmpty && turns < maxTurns) {
    Model<ModelTurn>("Call a tool when you need information; otherwise answer.")
        .tools(tools.map(\.descriptor))
        .input { $transcript }
        .assign(to: $lastTurn)
    Run($lastTurn) { turn in                                           // dispatch tool calls, append results
        guard let calls = turn.toolCalls, !calls.isEmpty else { return transcript }
        var updated = transcript
        for call in calls {
            let out = try await ToolRegistry(tools).executeJSON(
                toolName: call.name, inputJSON: Data(call.arguments.utf8))
            updated += "\n[\(call.name)] " + String(decoding: out, as: UTF8.self)
        }
        return updated
    }
    .assign(to: $transcript)
    $lastTurn.map { $0.reply ?? "" }.assign(to: $reply)
    $turns.map { $0 + 1 }.assign(to: $turns)
}
$reply
```

### [`CodingAgentPipeline`](../CodingAgent/CodingAgentPipeline.swift)
The `ResearchAssistant` shape scaled up into a real coding agent: file/`bash` tools, context
**compaction** (a sub-pipeline that summarizes the older transcript when it nears the window),
stall recovery, and a swappable agent behind the `ChatAgent` protocol. It lives in the
`CodingAgent/` target and powers the `cp-agent` executable.

```swift
While(reply.isEmpty && turns < maxTurns) {
    // Near the context window? Summarize the older transcript instead of dropping it; else take a turn.
    if compaction && transcript.count > compactionTrigger {
        CompactTranscript(summary: $compactionSummary, transcript: $transcript, /* head/middle/tail */)
    } else {
        // `systemPrompt` is a computed property over `let`s (no @State read), so `.assign` is safe.
        Model<ModelTurn>(systemPrompt)
            .tools(tools.map(\.descriptor))
            .input { $transcript }                            // no maxTokens → server default
            .assign(to: $lastTurn)
        Run($lastTurn) { turn in /* run tool calls, append results */ }.assign(to: $transcript)
        $lastTurn.map { $0.toolCalls?.isEmpty == false ? "" : ($0.reply ?? "") }.assign(to: $reply)
        $turns.map { $0 + 1 }.assign(to: $turns)
    }
}
$reply
```

See the [README worked example](../README.md#worked-example-a-coding-agent-as-a-pipeline) for the
full walkthrough — tool dispatch, compaction, and the `ChatAgent` seam.

## Running them

Drive any example through the compiler and walker with a `MockExecutor` (ships with the package) or
your own `Executor`. See [Getting started](getting-started.md) and the [Executors](executors.md) reference.
