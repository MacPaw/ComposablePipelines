//
//  CodingAgentTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
import ComposablePipelines
import ExecutionEngine
import PipelineAST
@testable import CodingAgent

// MARK: - Path jail

final class PathJailTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-jail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testResolve_withinRoot_ok() throws {
        let url = try PathJail(root: root).resolve("a/b.txt")
        XCTAssertTrue(url.path.hasSuffix("/a/b.txt"))
    }

    func testResolve_rejectsParentEscape() {
        let jail = PathJail(root: root)
        XCTAssertThrowsError(try jail.resolve("../escape"))
        XCTAssertThrowsError(try jail.resolve("a/../../escape"))
    }

    func testResolve_rejectsAbsoluteOutsideRoot() {
        XCTAssertThrowsError(try PathJail(root: root).resolve("/etc/passwd"))
    }

    func testResolve_rejectsSymlinkEscape() throws {
        // A symlink created *inside* the jail must not grant access to its target outside the jail.
        let link = root.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        let jail = PathJail(root: root)
        XCTAssertThrowsError(try jail.resolve("escape-link/secret.txt"))
        XCTAssertThrowsError(try jail.resolve("escape-link"))
    }
}

// MARK: - Tools

final class CodingToolsTests: XCTestCase {
    private var root: URL!
    private var jail: PathJail!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        jail = PathJail(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWriteThenRead_roundTrips() async throws {
        let write = try await WriteFileTool(jail: jail).call(.init(path: "src/f.swift", content: "hello"))
        XCTAssertTrue(write.hasPrefix("wrote "), write)
        let read = try await ReadFileTool(jail: jail).call(.init(path: "src/f.swift"))
        XCTAssertEqual(read, "hello")
    }

    func testEdit_uniqueReplacement_andAmbiguity() async throws {
        _ = try await WriteFileTool(jail: jail).call(.init(path: "f.txt", content: "one two three"))
        let edited = try await EditFileTool(jail: jail)
            .call(.init(path: "f.txt", old_string: "two", new_string: "2"))
        XCTAssertTrue(edited.hasPrefix("edited "), edited)
        let read = try await ReadFileTool(jail: jail).call(.init(path: "f.txt"))
        XCTAssertEqual(read, "one 2 three")

        _ = try await WriteFileTool(jail: jail).call(.init(path: "dup.txt", content: "x x"))
        let ambiguous = try await EditFileTool(jail: jail)
            .call(.init(path: "dup.txt", old_string: "x", new_string: "y"))
        XCTAssertTrue(ambiguous.contains("ambiguous"), ambiguous)
    }

    func testListAndGrep() async throws {
        _ = try await WriteFileTool(jail: jail).call(.init(path: "a.txt", content: "find the needle here"))
        let listed = try await ListDirTool(jail: jail).call(.init(path: nil))
        XCTAssertTrue(listed.contains("a.txt"), listed)
        let grepped = try await GrepTool(jail: jail).call(.init(pattern: "needle", path: nil))
        XCTAssertTrue(grepped.contains("a.txt:1:"), grepped)
        XCTAssertTrue(grepped.contains("needle"), grepped)
    }

    func testTool_pathEscape_returnsErrorString() async throws {
        let read = try await ReadFileTool(jail: jail).call(.init(path: "../../etc/passwd"))
        XCTAssertTrue(read.hasPrefix("error:"), read)
        XCTAssertTrue(read.contains("escapes"), read)
    }
}

// MARK: - Agent loop integration (scripted executor)

/// Returns a pre-scripted `ModelTurn` per call — no real model. Drives the full
/// compile → walk → executor → tool-dispatch path deterministically.
private final class ScriptedExecutor: Executor, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let turns: [ModelTurn]
    init(_ turns: [ModelTurn]) { self.turns = turns }

    func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        lock.lock()
        let turn = turns[Swift.min(index, turns.count - 1)]
        index += 1
        lock.unlock()
        return try JSONEncoder().encode(turn)
    }
}

/// Like ``ScriptedExecutor`` but records the user message string of every turn, so tests can assert
/// what context the pipeline actually sent to the model.
private final class CapturingExecutor: Executor, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let turns: [ModelTurn]
    private(set) var messages: [String] = []
    private(set) var maxTokens: [Int?] = []
    init(_ turns: [ModelTurn]) { self.turns = turns }

    func runModel(
        config: ModelConfig,
        arguments: ModelArguments,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> ExecutionValue {
        lock.lock()
        if case .string(let text)? = arguments.message { messages.append(text) }
        maxTokens.append(arguments.maxTokens)
        let turn = turns[Swift.min(index, turns.count - 1)]
        index += 1
        lock.unlock()
        // Honor the requested output type: ModelTurn steps get the scripted turn; String steps
        // (e.g. the compaction summarizer) get its reply text.
        if config.outputTypeName == ModelTurn.outputTypeName {
            return try JSONEncoder().encode(turn)
        }
        return try JSONEncoder().encode(turn.reply ?? "")
    }
}

final class CodingAgentLoopTests: XCTestCase {
    func testAgentLoop_runsToolThenReplies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jail = PathJail(root: root)
        let script: [ModelTurn] = [
            ModelTurn(toolCalls: [ToolCall(
                id: "1", name: "write_file",
                arguments: #"{"path":"hello.txt","content":"hi from agent"}"#)]),
            ModelTurn(reply: "Created hello.txt."),
        ]

        let pipeline = CodingAgentPipeline(
            task: "create hello.txt", tools: defaultCodingTools(jail: jail), maxTurns: 5)
        let result = try await PipelineRunner.run(pipeline, executor: ScriptedExecutor(script))

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "Created hello.txt.")
        let written = try String(
            contentsOf: root.appendingPathComponent("hello.txt"), encoding: .utf8)
        XCTAssertEqual(written, "hi from agent")
    }

    // A turn that carries a preamble reply *and* a tool call is not final — the loop must continue
    // and return the later tool-free answer, not the preamble.
    func testAgentLoop_preambleWithToolCall_keepsLooping() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script: [ModelTurn] = [
            ModelTurn(
                reply: "I'll create it.",
                toolCalls: [ToolCall(
                    id: "1", name: "write_file",
                    arguments: #"{"path":"a.txt","content":"x"}"#)]),
            ModelTurn(reply: "All done."),
        ]
        let pipeline = CodingAgentPipeline(
            task: "create a.txt", tools: defaultCodingTools(jail: PathJail(root: root)), maxTurns: 5)
        let result = try await PipelineRunner.run(pipeline, executor: ScriptedExecutor(script))

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "All done.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    // A single empty turn is transient — the loop nudges and continues, reaching the later answer.
    func testAgentLoop_recoversFromTransientEmptyTurn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script: [ModelTurn] = [ModelTurn(), ModelTurn(reply: "recovered")]
        let pipeline = CodingAgentPipeline(
            task: "x", tools: defaultCodingTools(jail: PathJail(root: root)), maxTurns: 5)
        let result = try await PipelineRunner.run(pipeline, executor: ScriptedExecutor(script))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "recovered")
    }

    // The configured per-response output budget reaches the model request.
    func testAgentLoop_usesConfiguredOutputBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executor = CapturingExecutor([ModelTurn(reply: "done")])
        let pipeline = CodingAgentPipeline(
            task: "x", tools: defaultCodingTools(jail: PathJail(root: root)),
            maxTurns: 3, contextTokens: 262_144, maxOutputTokens: 12_345)
        _ = try await PipelineRunner.run(pipeline, executor: executor)
        XCTAssertEqual(executor.maxTokens.first ?? nil, 12_345)
    }

    // When the transcript passes the compaction trigger, a compaction turn summarizes the older
    // middle and rewrites the transcript; the next turn runs on the compacted context.
    func testAgentLoop_compactsTranscriptWhenLarge() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Turn 1 writes a large file (its result balloons the transcript past the trigger); turn 2
        // is the compaction summarizer (String output → "COMPACTED"); turn 3 is the final answer.
        let bigContent = String(repeating: "x", count: 9_000)
        let script: [ModelTurn] = [
            ModelTurn(toolCalls: [ToolCall(
                id: "1", name: "write_file",
                arguments: #"{"path":"big.txt","content":"\#(bigContent)"}"#)]),
            ModelTurn(reply: "COMPACTED"),
            ModelTurn(reply: "done"),
        ]
        let executor = CapturingExecutor(script)
        // Small context (default 4096 output) → transcriptCap 8000, trigger 6000, so the ~9k write
        // forces compaction on the next turn.
        let pipeline = CodingAgentPipeline(
            task: "make big.txt", tools: defaultCodingTools(jail: PathJail(root: root)),
            maxTurns: 8, contextTokens: 8_192, maxOutputTokens: 4_096)
        let result = try await PipelineRunner.run(pipeline, executor: executor)

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "done")
        // A later turn's model input must show the compaction marker and the summary text.
        let compacted = executor.messages.first { $0.contains("[Earlier context compacted:]") }
        XCTAssertNotNil(compacted, "expected a compacted transcript to reach the model")
        XCTAssertTrue(compacted?.contains("COMPACTED") ?? false)
    }

    // Persistent empty turns end the loop with a clear note rather than spinning to maxTurns.
    func testAgentLoop_givesUpAfterPersistentEmptyTurns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = Array(repeating: ModelTurn(), count: 6)
        let pipeline = CodingAgentPipeline(
            task: "x", tools: defaultCodingTools(jail: PathJail(root: root)), maxTurns: 10)
        let result = try await PipelineRunner.run(pipeline, executor: ScriptedExecutor(script))
        let reply = try JSONDecoder().decode(String.self, from: result)
        XCTAssertTrue(reply.contains("empty turns"), "expected the give-up note, got: \(reply)")
    }
}

// MARK: - ChatAgent adapter

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var toolNames: [String] = []
    private(set) var thinkingCount = 0
    func append(_ event: AgentEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .thinking: thinkingCount += 1
        case .reasoning: break
        case .toolCall(let name, _): toolNames.append(name)
        }
    }
}

final class CodingAgentAdapterTests: XCTestCase {
    func testAdapter_emitsToolCalls_andReturnsReply() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script: [ModelTurn] = [
            ModelTurn(toolCalls: [ToolCall(
                id: "1", name: "write_file",
                arguments: #"{"path":"a.txt","content":"x"}"#)]),
            ModelTurn(reply: "done"),
        ]
        let agent = CodingAgentAdapter(
            executor: ScriptedExecutor(script), jail: PathJail(root: root), maxTurns: 5)

        let box = EventBox()
        let reply = try await agent.send("do it") { box.append($0) }

        XCTAssertEqual(reply, "done")
        XCTAssertTrue(box.toolNames.contains("write_file"), "expected a write_file tool event")
        XCTAssertGreaterThan(box.thinkingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testAdapter_threadsPriorTurnsIntoContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-mem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executor = CapturingExecutor([ModelTurn(reply: "first-answer"), ModelTurn(reply: "second-answer")])
        let agent = CodingAgentAdapter(executor: executor, jail: PathJail(root: root), maxTurns: 3)

        let first = try await agent.send("remember apples") { _ in }
        let second = try await agent.send("what did I say?") { _ in }

        XCTAssertEqual(first, "first-answer")
        XCTAssertEqual(second, "second-answer")
        // The second run's model input must carry the earlier exchange.
        let secondInput = try XCTUnwrap(executor.messages.last)
        XCTAssertTrue(secondInput.contains("remember apples"), "prior user message missing from context")
        XCTAssertTrue(secondInput.contains("first-answer"), "prior answer missing from context")
        XCTAssertTrue(secondInput.contains("what did I say?"), "new message missing")
    }
}
