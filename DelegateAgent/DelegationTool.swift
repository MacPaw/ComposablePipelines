//
//  DelegationTool.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import ComposablePipelines
import Foundation

/// The **control tool** a parent hands a model so the model can split its own work — and decide what
/// each subagent is allowed to use.
///
/// It is a tool only in the sense that the model calls it like one. Nothing executes it: the parent
/// never routes its name to a `ToolRegistry`, so a call is *read*, not run. That is the whole mechanism
/// — a tool is executable exactly when an author wired it to an executor, so an advertised-but-
/// unregistered tool is inherently inert. The model's call is decoded into ``DelegateBrief`` values that
/// become a `Delegate` leaf's task list, which is how one model turn reshapes the pipeline below it.
///
/// The parent's turn is deliberately given **this tool and nothing else**. On a small local model a
/// broad request in front of a full catalog makes the model reason for tens of seconds and stall; a
/// one-tool router decides fast, and each narrow subagent then picks from a handful of tools reliably.
///
/// ```swift
/// let menu = DelegationMenu(tools: allTools.map(\.descriptor), context: ["memory": recalled])
///
/// $routerTurn.set {
///     Model<ModelTurn>.plan(systemPrompt: DelegationTool.routerPrompt,
///                           tools: [DelegationTool.descriptor(menu: menu)])
///         .message(prompt)
/// }
/// $briefs.set { $routerTurn.map { DelegationTool.briefs(from: $0, menu: menu) } }
/// ```
///
/// An empty result means the model chose to answer directly — a pure-knowledge question needs no
/// subagents, and one call is the whole run.
///
/// - Author: Claude
public enum DelegationTool {

    /// The advertised name. Not registered anywhere — see the type's discussion.
    public static let name = "delegate_to_specialists"

    // MARK: - Descriptor

    /// Builds the tool the router turn is given, with `menu`'s tools and context labels spelled out.
    ///
    /// The menu goes into the **description prose** rather than the schema because ``JSONSchema`` has no
    /// `enum` case — it cannot say "one of these strings". Validation therefore happens on the way back
    /// in ``briefs(from:menu:)``, which is where it has to be anyway: a small model will invent a name
    /// no matter how the choice is expressed.
    ///
    /// The framing is load-bearing. The model must understand that delegating is *how* tool work gets
    /// done — that its specialists hold the tools it lacks. Told merely to "break the request up", a
    /// reasoning model concludes it has no weather tool and so cannot answer, then refuses or fabricates
    /// data instead of delegating.
    ///
    /// - Author: Claude
    public static func descriptor(menu: DelegationMenu) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: Self.toolDescription(menu: menu),
            inputSchema: .object(
                properties: [
                    "subtasks": .array(
                        items: .object(
                            properties: [
                                "instruction": .string,
                                "tools": .array(items: .string),
                                "context": .array(items: .string)
                            ],
                            required: ["instruction"]
                        )
                    )
                ],
                required: ["subtasks"]
            )
        )
    }

    // MARK: - Decoding

    /// Reads the router turn's decision: one ``DelegateBrief`` per subtask the model asked for, or `[]`
    /// when it did not call the tool (⇒ answer directly).
    ///
    /// Everything a small local model gets wrong is absorbed here rather than failing the run:
    /// - a chain-of-thought preamble around the arguments (stripped via ``DelegateDistiller``),
    /// - extra keys the model invents next to the ones asked for (`reasoning`, `confidence`, …) — a
    ///   strict dictionary decode would fail the whole parse and silently drop the delegation,
    /// - a tool or context name that is not on `menu` (dropped),
    /// - a blank instruction (dropped — a subagent with nothing to do still costs a spawn slot),
    /// - a split **written out as text** rather than called as a tool (see ``recoverArguments(from:)``).
    ///
    /// Dropping rather than erroring is what keeps the grant one-way: the result is always a subset of
    /// what the parent published, so no completion can widen a subagent's reach.
    ///
    /// - Author: Claude
    public static func briefs(from turn: ModelTurn, menu: DelegationMenu) -> [DelegateBrief] {
        let arguments = turn.toolCalls?.first(where: { $0.name == name })?.arguments
        guard let decoded = arguments.flatMap(decodeArguments)
                ?? recoverArguments(from: turn.reply ?? "") else { return [] }

        return decoded.subtasks.compactMap { subtask in
            let instruction = subtask.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return nil }
            // Filter the menu, not the request: keeps declaration order and drops invented names.
            let requested = Set(subtask.tools?.values ?? [])
            let granted = menu.toolNames.filter(requested.contains)
            let items = (subtask.context?.values ?? []).flatMap { menu.context[$0] ?? [] }
            return DelegateBrief(instruction: instruction, toolNames: granted, contextItems: items)
        }
    }

    // MARK: - Execution

    /// Runs a subagent's turn against **its own** brief, then returns the text the parent gathers.
    ///
    /// **Every** call the turn carries is run, in the order the model emitted them, and the results are
    /// concatenated. Taking only the first silently discarded the rest: a dropped call is neither
    /// executed nor reported back as text, so the model cannot tell it asked for something that never
    /// happened. Parallel calls are a shape the parser produces — ``ToolCallTextRecovery`` splits a
    /// Pythonic block into its individual calls — so the consumer has to handle them.
    ///
    /// Sequential rather than concurrent: tools have side effects, and the model wrote an order.
    ///
    /// The allowlist is enforced a second time here, at execution. Narrowing what the model was shown
    /// stops it *choosing* a tool outside its brief; this stops a hallucinated name from *landing* — the
    /// two together mean a subagent cannot reach past its grant by either route. A rejected or failing
    /// call becomes text the model can read, never a thrown error: one malformed call must not abort the
    /// subagent, let alone the delegate.
    ///
    /// - Author: Claude
    public static func resolve(
        turn: ModelTurn,
        brief: DelegateBrief,
        tools: [any ToolExecutor]
    ) async -> String {
        let executable = tools.filter { Set(brief.toolNames).contains($0.descriptor.name) }
        return await resolve(turn: turn, brief: brief) { await run($0, tools: executable) }
    }

    /// The same resolve, over a caller-supplied executor.
    ///
    /// The grant is the part that belongs here; *how* a granted call runs is the host's. A host with a
    /// richer execution path than a bare ``ToolRegistry`` — one that reports each call to a run's
    /// trajectory, or applies its own approval gate — passes it as `execute` and still gets the brief
    /// enforced identically. This package cannot depend on such a path, so it takes a closure rather
    /// than a type.
    ///
    /// `execute` is called **only** for a call the brief grants; a rejected name never reaches it.
    ///
    /// - Author: Claude
    public static func resolve(
        turn: ModelTurn,
        brief: DelegateBrief,
        execute: (ToolCall) async -> String
    ) async -> String {
        let preamble = DelegateDistiller.strippingReasoning(turn.reply ?? "")
        let calls = turn.toolCalls ?? []
        guard !calls.isEmpty else { return preamble }

        let granted = Set(brief.toolNames)
        var sections: [String] = []
        for call in calls {
            guard granted.contains(call.name) else {
                let allowed = brief.toolNames.isEmpty ? "none" : brief.toolNames.joined(separator: ", ")
                sections.append("Tool '\(call.name)' is not available to you. Available: \(allowed).")
                continue
            }
            sections.append(await execute(call))
        }
        return ([preamble] + sections).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Prompts

    /// The system prompt for the routing turn — pairs with ``descriptor(menu:)``'s framing.
    public static let routerPrompt = """
        You lead a team of specialist agents. You have exactly ONE tool: `\(name)`. You have no \
        search/news/weather/translation/etc. tool of your own — your specialists do, and they will carry \
        out whatever tasks you hand them and return the results.

        - If the request needs ANY live data, tool, or action — or has several independent parts — call \
        `\(name)` and list EACH part as its own entry in `subtasks`. For every entry, name in `tools` \
        only the tools that part actually needs, and in `context` only the context it actually needs; a \
        specialist given fewer tools chooses better. Delegating is HOW that work gets done; do NOT try \
        to do it yourself and do NOT make up data (e.g. never invent "latest news").
        - Only answer directly, without delegating, for a general-knowledge question you can fully and \
        accurately answer from what you already know (e.g. "what is a monad?").
        """

    /// The system prompt each subagent runs with: one subtask, the tools its brief granted, nothing else.
    public static let workerPrompt = """
        Answer this single subtask. Use one of your tools if it helps, then answer concisely. Only the \
        tools listed for you are available — if none fit, answer from what you know.
        """

    // MARK: - Private

    /// The tool-call arguments, decoded as a struct so extra keys the model adds are ignored.
    private struct Arguments: Decodable {
        struct Subtask: Decodable {
            let instruction: String
            let tools: StringList?
            let context: StringList?
        }
        let subtasks: [Subtask]
    }

    /// A list of strings that also accepts a bare string.
    ///
    /// Small models write `"context": "the user's city"` about as often as `"context": ["city"]`, and the
    /// schema cannot stop them — ``JSONSchema`` describes the shape but nothing enforces it on the way
    /// back. Before this, one scalar in one optional field failed the whole `Arguments` decode and the
    /// delegation was discarded **entire** — instruction, tools and all — even when the rest was perfect.
    ///
    /// The losses are not junk when it happens: an otherwise-correct call named
    /// `convert_units` for "how far is 250 km in miles", which is exactly the right answer. A scalar in a
    /// field the parent is about to clamp against its own menu anyway is not worth an aborted delegation.
    ///
    /// - Author: Claude
    struct StringList: Decodable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([String].self) {
                values = list
            } else if let single = try? container.decode(String.self) {
                values = single.isEmpty ? [] : [single]
            } else {
                // A number, an object, anything else: treat as "said nothing", not as a failed parse.
                values = []
            }
        }
    }

    /// Recovers a split the model **wrote out** instead of calling the tool with.
    ///
    /// The failure this exists for is not a bad decision — it is a missing envelope. Asked to split "I
    /// need a throwaway login secret, 24 characters", the model replied, in plain text:
    ///
    /// ```json
    /// [{ "instruction": "Generate a random password of 24 characters",
    ///    "tools": ["generate_password"], "context": "…" }]
    /// ```
    ///
    /// Correct instruction, correct grant, no tool call. Reading only `toolCalls` threw it away. Measured
    /// a recurring source of lost delegations.
    ///
    /// Two shapes are accepted: the full `{"subtasks": [...]}` object, and the bare `[...]` array of
    /// subtasks the model tends to write when it has stopped thinking of this as a call.
    ///
    /// **Only text past the reasoning counts.** A split sketched inside `<think>` is deliberation, not a
    /// decision — the model routinely drafts and then discards one — so ``DelegateDistiller`` strips it
    /// first. Recovery cannot widen anything either way: the result runs through the same clamp against
    /// the parent's menu as a real call does.
    ///
    /// - Author: Claude
    private static func recoverArguments(from reply: String) -> Arguments? {
        let stripped = DelegateDistiller.strippingReasoning(reply)
        if let decoded = decodeArguments(stripped) { return decoded }

        // The bare-array form: no `subtasks` key, just the list it would have held.
        guard let start = stripped.firstIndex(of: "["),
              let end = stripped.lastIndex(of: "]"),
              start <= end,
              let data = String(stripped[start...end]).data(using: .utf8),
              let subtasks = try? JSONDecoder().decode([Arguments.Subtask].self, from: data),
              !subtasks.isEmpty
        else { return nil }
        return Arguments(subtasks: subtasks)
    }

    /// Decodes the raw argument string, tolerating a reasoning preamble and trailing commentary by
    /// taking the outermost `{…}`.
    private static func decodeArguments(_ raw: String) -> Arguments? {
        let stripped = DelegateDistiller.strippingReasoning(raw)
        guard let start = stripped.firstIndex(of: "{"),
              let end = stripped.lastIndex(of: "}"),
              start <= end,
              let data = String(stripped[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Arguments.self, from: data)
    }

    /// Executes one granted call, turning any failure into readable text.
    private static func run(_ call: ToolCall, tools: [any ToolExecutor]) async -> String {
        let registry = ToolRegistry(tools)
        do {
            let data = try await registry.executeJSON(
                toolName: call.name,
                inputJSON: Data(call.arguments.utf8)
            )
            // Tool outputs are JSON; unwrap a bare string so the model reads prose, not a quoted blob.
            return (try? JSONDecoder().decode(String.self, from: data))
                ?? String(decoding: data, as: UTF8.self)
        } catch {
            return "Tool '\(call.name)' error: \(error.localizedDescription)"
        }
    }

    /// The description the router model reads: the framing, then the menu it may draw on.
    private static func toolDescription(menu: DelegationMenu) -> String {
        let toolLines = menu.tools
            .map { "  - \($0.name): \($0.description.prefix(120))" }
            .joined(separator: "\n")
        let contextLine = menu.contextLabels.isEmpty
            ? "  (no shareable context)"
            : "  " + menu.contextLabels.joined(separator: ", ")
        return """
            Hand the request to your team of specialist agents. Each specialist will actually PERFORM \
            the task you assign and return the result. This is HOW the work gets done: you have none of \
            these tools yourself, your specialists do — so do NOT try to call them, put those tasks in \
            `subtasks` instead.

            `subtasks` MUST be a non-empty array; a single task is a one-item list. Each entry has:
              - `instruction` (required): one self-contained instruction string.
              - `tools`: the tool names THIS specialist needs. Give each specialist only what its part \
            needs — an empty list means it answers from knowledge alone.
              - `context`: the context labels THIS specialist needs.

            Tools you may assign:
            \(toolLines.isEmpty ? "  (none)" : toolLines)

            Context labels you may assign:
            \(contextLine)

            Example — for "what's the weather in Kyiv and convert 100 USD to euros", call it with \
            subtasks: [{"instruction": "Get the weather forecast for Kyiv", "tools": ["get_weather"]}, \
            {"instruction": "Convert 100 USD to EUR", "tools": ["convert_currency"]}].
            """
    }
}
