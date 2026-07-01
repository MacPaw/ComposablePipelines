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
        $keyPoints.set { Model<String>().systemPrompt("Extract the 5 key points.").message(document) }
        $draft.set    { Model<String>().systemPrompt("Summarize from these points.").input { $keyPoints.get() } }
        Group { $summary.set { Summarize(text: $draft, maxTokens: 512) } }
    }
}
```

## Parallel fan-out and merge

### [`ContentWriterPipeline`](../Examples/ContentWriterPipeline.swift)
The three critiques read `draft` but not each other, so the compiler runs them **in parallel**; the
rewrite depends on all three and waits for them. (The full source also gates the topic with a
`Guardrail`.)

```swift
$draft.set { Model<String>().systemPrompt("Write a short article on the topic.").input { $topic.get() } }

// No data dependency between these three → they run concurrently.
$grammarNotes.set { Model<String>().systemPrompt("Review grammar. Be concise.").input { $draft.get() } }
$styleNotes.set   { Model<String>().systemPrompt("Review tone & style. Be concise.").input { $draft.get() } }
$factNotes.set    { Model<String>().systemPrompt("Flag unsupported claims. Be concise.").input { $draft.get() } }

$finalDraft.set {
    Model<String>()
        .systemPrompt("Rewrite applying:\nGrammar: \(grammarNotes)\nStyle: \(styleNotes)\nFacts: \(factNotes)")
        .input { $draft.get() }
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
        ForEach(in: documents) { document in                       // one step per element
            $notes.set {
                Model<String>()
                    .systemPrompt("Summarize in one line, append to the notes:\n\(document)")
                    .input { $notes.get() }                        // reads what the prior iteration committed
            }
        }
        $digest.set { Model<String>().systemPrompt("Two-sentence digest of these notes.").input { $notes.get() } }
    }
}
```

## Branching on model output

### [`CodeReviewPipeline`](../Examples/CodeReviewPipeline.swift)
Request models by capability, not name (`requirements:`); branch on the produced verdict; and
short-circuit with `Self.return` to skip the expensive path.

```swift
$verdict.set {                                                     // cheap triage, quick local model
    Model<String>()
        .requirements(ModelSelectionRequirements(traits: [.quick, .localOnly]))
        .systemPrompt("Triage: reply 'trivial' or 'needs-review'.")
        .input { $diff.get() }
}
if verdict == "trivial" {                                          // reactive branch on the result
    Self.return("LGTM — trivial change.")                          // skip the expensive model
}
$review.set {                                                      // escalate to a reasoning model
    Model<String>()
        .requirements(ModelSelectionRequirements(traits: [.reasoning]))
        .systemPrompt("Thorough review; list concerns.")
        .input { $diff.get() }
}
$review.get()
```

### [`ContentModerationPipeline`](../Examples/ContentModerationPipeline.swift)
A `Guardrail` gates the input; `if`/`else` on the classified severity picks the path.

```swift
Guardrail(input, rules: [.politics, .pii], allowed: {
    $severity.set { Model<String>().systemPrompt("Classify severity…").input { $input.get() } }
    if severity == "safe" {
        $explanation.set("Content is safe. No action needed.")
    } else {
        $explanation.set { Model<String>().systemPrompt("Explain the violation…").input { $input.get() } }
    }
}, blocked: {
    Just(value: "I can't help with that — it conflicts with the safety policy.")
})
```

## Routing and composition

### [`CustomerSupportPipeline`](../Examples/CustomerSupportPipeline.swift)
Classify intent, then `switch` to specialized handling per category.

```swift
$intent.set { Model<String>().systemPrompt("Classify: billing, technical, feedback, general").input { $message.get() } }
switch intent {
case "billing":   $reply.set { Model<String>().systemPrompt("Draft a billing response.").input { $message.get() } }
case "technical": $reply.set { Model<String>().systemPrompt("Write troubleshooting steps.").input { $message.get() } }
default:          $reply.set { Model<String>().systemPrompt("Provide a helpful response.").input { $message.get() } }
}
$reply.get()
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
        $context.set { From(knowledgeBase, query: $question) }             // retrieve
        $answer.set {                                                      // answer from context only
            Model<String>()
                .systemPrompt("Answer using only the provided context; else say you don't know.")
                .input { $context.get() }
        }
    }
}
```

## Loops, retries, and agents

### [`SelfHealingExtractionPipeline`](../Examples/SelfHealingExtractionPipeline.swift)
A `While` retry loop over ordinary `@State`: ask for JSON, validate in plain Swift via `ClientTask`,
and fold the previous error back into the next prompt until it's valid or attempts run out.

```swift
While(condition: { !valid && attempts < maxAttempts }) {
    $candidate.set {
        Model<String>()
            .systemPrompt("Extract {\"name\",\"age\"} as JSON. \(lastError.isEmpty ? "" : "Previous error: \(lastError)")")
            .message(text)
    }
    $valid.set     { ClientTask(input: $candidate) { Self.isValidPersonJSON($0) } }
    $lastError.set { ClientTask(input: $candidate) { Self.isValidPersonJSON($0) ? "" : "expected name and age" } }
    $attempts.set  { ClientTask(input: $attempts) { $0 + 1 } }
}
$candidate.get()
```

### [`ResearchAssistantPipeline`](../Examples/ResearchAssistantPipeline.swift)
A tool-calling agent loop: each turn the model calls tools or answers; tool results feed back into
the transcript until it returns a final reply.

```swift
While(condition: { reply.isEmpty && turns < maxTurns }) {
    $lastTurn.set {
        Model<ModelTurn>().tools(tools.map(\.descriptor))
            .systemPrompt("Call a tool when you need information; otherwise answer.")
            .input { $transcript.get() }
    }
    $transcript.set {                                                  // dispatch tool calls, append results
        ClientTask(input: $lastTurn) { turn in
            guard let calls = turn.toolCalls, !calls.isEmpty else { return transcript }
            var updated = transcript
            for call in calls {
                let out = try await ToolRegistry(tools).executeJSON(
                    toolName: call.name, inputJSON: Data(call.arguments.utf8))
                updated += "\n[\(call.name)] " + String(decoding: out, as: UTF8.self)
            }
            return updated
        }
    }
    $reply.set { ClientTask(input: $lastTurn) { $0.reply ?? "" } }
    $turns.set { ClientTask(input: $turns) { $0 + 1 } }
}
$reply.get()
```

> The coding agent in the [README](../README.md#worked-example-a-coding-agent-as-a-pipeline) is this
> same shape, scaled up with real file/`bash` tools, context compaction, and a swappable agent.

## Running them

Drive any example through the compiler and walker with a `MockExecutor` (ships with the package) or
your own `Executor`. See [Getting started](getting-started.md) and the [Executors](executors.md) reference.
