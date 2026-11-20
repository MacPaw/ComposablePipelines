//
//  DelegationGrantEndToEndTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import PipelineAST
import PipelineDSL
import PipelineCompiler
import ExecutionEngine
import ComposablePipelines
import DelegateAgent

/// Model-chosen delegation grants, end to end: DSL → lowering → compilation → walk.
///
/// This crosses every layer the feature touches — the router's tool call, the host transform that decodes
/// it, the `.delegate` leaf's per-child seeding, `ModelConfig.toolAllowlistSlotID` in the walker, and
/// `DelegationTool.resolve` at execution. Unit tests on the decoder alone cannot show the thing that
/// actually matters: that two siblings of the *same* lowered child graph end up seeing *different* tools.
final class DelegationGrantEndToEndTests: XCTestCase {

    // MARK: - Fixtures

    private static func tool(_ name: String) -> ToolDescriptor {
        ToolDescriptor(name: name, description: "does \(name)", inputSchema: .object(properties: [:]))
    }

    private static let menu = DelegationMenu(
        tools: [tool("get_weather"), tool("convert_currency"), tool("web_search")],
        context: ["docs": [ContextItem(kind: .custom("doc"), source: "test", value: .string("doc-a"))]]
    )

    /// The shape `AdaptiveDelegateDemoPipeline` uses: one routing turn, then a delegate whose children
    /// unpack their own brief and narrow themselves to it.
    private struct RoutingPipeline: Pipeline {
        typealias Output = [String?]
        let tools: [any ToolExecutor]

        /// A computed instance property captured into the host transform — the same spelling
        /// `AdaptiveDelegateDemoPipeline` uses, so this test also pins that shape compiling.
        private var menu: DelegationMenu { DelegationGrantEndToEndTests.menu }

        @State var routerTurn = ModelTurn()
        @State var briefs: [DelegateBrief] = []
        @State var brief = DelegateBrief(instruction: "")
        @State var instruction: String = ""
        @State var grantedTools: [String] = []
        @State var grantedContext: [ContextItem] = []
        @State var workerTurn = ModelTurn()

        var body: some Pipeline {
            $routerTurn.set {
                Model<ModelTurn>.plan(
                    systemPrompt: DelegationTool.routerPrompt,
                    tools: [DelegationTool.descriptor(menu: menu)]
                )
                .message("weather in Kyiv and 100 USD to EUR")
            }
            $briefs.set { [menu] in $routerTurn.map { DelegationTool.briefs(from: $0, menu: menu) } }
            Delegate(tasks: $briefs, taskInput: $brief, budget: .init(total: 8, leafReserve: 0),
                     inherit: [.tools]) {
                $instruction.set { $brief.map(\.instruction) }
                $grantedTools.set { $brief.map(\.toolNames) }
                $grantedContext.set { $brief.map(\.contextItems) }
                $workerTurn.set {
                    Model<ModelTurn>.plan(
                        systemPrompt: DelegationTool.workerPrompt,
                        tools: menu.tools
                    )
                    .toolAllowlist($grantedTools)
                    .contextItems($grantedContext)
                    .input { $instruction.get() }
                }
                Run($workerTurn, $brief) { [tools] turn, granted in
                    await DelegationTool.resolve(turn: turn, brief: granted, tools: tools)
                }
            }
        }
    }

    // MARK: - Executor

    /// Answers the router with a fixed delegation call, then each worker with a call to whatever tool it
    /// is told to use — while recording the catalog every worker was actually advertised.
    private final class GrantSpyExecutor: Executor, @unchecked Sendable {
        private let lock = NSLock()
        private var advertised: [String: [String]] = [:]
        private var contexts: [String: [String]] = [:]
        private let routerArguments: String
        /// Tools each worker will *attempt*, keyed by a substring of its instruction, emitted as one
        /// turn. Absent ⇒ plain reply. A list rather than a single name so a worker can emit the
        /// parallel calls the Pythonic parser produces.
        private let workerAttempts: [String: [String]]

        init(routerArguments: String, workerAttempts: [String: [String]]) {
            self.routerArguments = routerArguments
            self.workerAttempts = workerAttempts
        }

        /// Tool names the worker whose instruction contains `key` was shown.
        func tools(forWorkerMatching key: String) -> [String]? {
            lock.withLock { advertised.first { $0.key.contains(key) }?.value }
        }

        func context(forWorkerMatching key: String) -> [String]? {
            lock.withLock { contexts.first { $0.key.contains(key) }?.value }
        }

        func runModel(
            config: ModelConfig,
            arguments: ModelArguments,
            onDelta: (@Sendable (String) -> Void)?
        ) async throws -> ExecutionValue {
            let message = Self.text(arguments.message)
            // The router's turn is the one with no message-driven instruction match.
            if message.contains("weather in Kyiv and") {
                return try JSONEncoder().encode(ModelTurn(toolCalls: [
                    ToolCall(id: "r", name: DelegationTool.name, arguments: routerArguments)
                ]))
            }
            lock.withLock {
                advertised[message] = arguments.tools.map(\.name)
                contexts[message] = arguments.contextItems.compactMap {
                    if case let .string(value) = $0.value { return value } else { return nil }
                }
            }
            guard let attempts = workerAttempts.first(where: { message.contains($0.key) })?.value else {
                return try JSONEncoder().encode(ModelTurn(reply: "knew it already"))
            }
            return try JSONEncoder().encode(ModelTurn(toolCalls: attempts.enumerated().map {
                ToolCall(id: "w\($0.offset)", name: $0.element, arguments: "{}")
            }))
        }

        private static func text(_ message: JSONValue?) -> String {
            guard let message, let data = try? JSONEncoder().encode(message) else { return "" }
            return (try? JSONDecoder().decode(String.self, from: data))
                ?? String(decoding: data, as: UTF8.self)
        }
    }

    /// Records whether it ran, so a rejected call can be proven not to have executed.
    private final class SpyTool: ToolExecutor, @unchecked Sendable {
        let descriptor: ToolDescriptor
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        init(_ name: String) { descriptor = DelegationGrantEndToEndTests.tool(name) }

        func callJSON(_ inputJSON: Data) async throws -> Data {
            lock.withLock { calls += 1 }
            return try JSONEncoder().encode("\(descriptor.name) result")
        }
    }

    private func run(
        tools: [any ToolExecutor],
        executor: GrantSpyExecutor
    ) async throws -> [String?] {
        let lowered = RoutingPipeline(tools: tools).lowered()
        let graph = PipelineCompiler(optimizations: [.parallelize]).compile(lowered.graph)
        let out = try await PipelineWalker(executor: executor).run(
            graph: graph,
            clientActionProvider: PipelineWalker.clientActionProvider(from: lowered.clientActions),
            contextProviders: lowered.contextProviders
        )
        return try JSONDecoder().decode([String?].self, from: out)
    }

    // MARK: - Tests

    func testSiblingsOfOneChildGraphSeeDifferentTools() async throws {
        let weather = SpyTool("get_weather")
        let currency = SpyTool("convert_currency")
        let search = SpyTool("web_search")
        let executor = GrantSpyExecutor(
            routerArguments: """
                {"subtasks": [
                  {"instruction": "Weather in Kyiv", "tools": ["get_weather"]},
                  {"instruction": "Convert 100 USD to EUR", "tools": ["convert_currency"]}
                ]}
                """,
            workerAttempts: ["Weather": ["get_weather"], "Convert": ["convert_currency"]]
        )

        let answers = try await run(tools: [weather, currency, search], executor: executor)

        XCTAssertEqual(answers, ["get_weather result", "convert_currency result"],
                       "each subagent ran its own granted tool and the results gather in task order")
        XCTAssertEqual(executor.tools(forWorkerMatching: "Weather"), ["get_weather"])
        XCTAssertEqual(executor.tools(forWorkerMatching: "Convert"), ["convert_currency"])
        XCTAssertEqual(search.callCount, 0, "a tool no brief asked for is never reached")
    }

    func testAGrantOfNoToolsLeavesTheSubagentWithNone() async throws {
        let weather = SpyTool("get_weather")
        let executor = GrantSpyExecutor(
            routerArguments: #"{"subtasks": [{"instruction": "Define a monad", "tools": []}]}"#,
            workerAttempts: [:]
        )
        let answers = try await run(tools: [weather], executor: executor)
        XCTAssertEqual(answers, ["knew it already"])
        XCTAssertEqual(executor.tools(forWorkerMatching: "monad"), [],
                       "an explicit empty grant reaches the model as a tool-less turn")
    }

    func testProvisionedContextReachesOnlyTheSubagentThatAskedForIt() async throws {
        let executor = GrantSpyExecutor(
            routerArguments: """
                {"subtasks": [
                  {"instruction": "Summarize the papers", "context": ["docs"]},
                  {"instruction": "Say hello", "context": []}
                ]}
                """,
            workerAttempts: [:]
        )
        _ = try await run(tools: [], executor: executor)
        XCTAssertEqual(executor.context(forWorkerMatching: "Summarize"), ["doc-a"])
        XCTAssertEqual(executor.context(forWorkerMatching: "hello"), [],
                       "context is provisioned per child, not shared across the fan-out")
    }

    func testASubagentCannotReachPastItsGrantEvenByHallucinatingAName() async throws {
        // The worker is told to attempt `convert_currency`, which its brief never granted. Narrowing
        // stopped it being offered; `resolve` must stop it landing.
        let weather = SpyTool("get_weather")
        let currency = SpyTool("convert_currency")
        let executor = GrantSpyExecutor(
            routerArguments: #"{"subtasks": [{"instruction": "Weather in Kyiv", "tools": ["get_weather"]}]}"#,
            workerAttempts: ["Weather": ["convert_currency"]]
        )

        let answers = try await run(tools: [weather, currency], executor: executor)

        XCTAssertEqual(currency.callCount, 0, "the ungranted tool must never execute")
        let answer = try XCTUnwrap(answers.first ?? nil)
        XCTAssertTrue(answer.contains("not available"))
        XCTAssertTrue(answer.contains("get_weather"), "the refusal names what the subagent may use")
    }

    func testInventedToolNamesInTheRouterCallAreDroppedBeforeFanOut() async throws {
        let weather = SpyTool("get_weather")
        let executor = GrantSpyExecutor(
            routerArguments: """
                {"subtasks": [{"instruction": "Weather in Kyiv",
                               "tools": ["get_weather", "launch_missiles"]}]}
                """,
            workerAttempts: ["Weather": ["get_weather"]]
        )
        _ = try await run(tools: [weather], executor: executor)
        XCTAssertEqual(executor.tools(forWorkerMatching: "Weather"), ["get_weather"],
                       "a grant is always a subset of the published menu")
    }

    func testASubagentsParallelCallsAllRunAndGatherInOrder() async throws {
        // The parser splits a Pythonic block into its individual calls, so a worker turn can carry
        // several. Keeping only the first dropped the rest silently: unexecuted and unreported, so the
        // model had no way to notice it asked for something that never happened.
        let weather = SpyTool("get_weather")
        let currency = SpyTool("convert_currency")
        let executor = GrantSpyExecutor(
            routerArguments: """
                {"subtasks": [{"instruction": "Weather in Kyiv and 100 USD to EUR",
                               "tools": ["get_weather", "convert_currency"]}]}
                """,
            workerAttempts: ["Weather": ["get_weather", "convert_currency"]]
        )

        let answers = try await run(tools: [weather, currency], executor: executor)

        XCTAssertEqual(answers, ["get_weather result\n\nconvert_currency result"],
                       "both calls ran and their results concatenate in the order the model wrote them")
        XCTAssertEqual(weather.callCount, 1)
        XCTAssertEqual(currency.callCount, 1, "the second call must not be dropped")
    }

    func testNoDelegationCallFansOutToNothing() async throws {
        let executor = GrantSpyExecutor(
            routerArguments: #"{"subtasks": []}"#,
            workerAttempts: [:]
        )
        let answers = try await run(tools: [], executor: executor)
        XCTAssertEqual(answers, [], "an empty decision means the parent answers directly")
    }
}
