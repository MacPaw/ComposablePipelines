//
//  AgentLoopBuildSiteTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

// Exit tests arrived in Swift 6.2; on an older compiler this file is empty.
#if compiler(>=6.2)
import Testing
import ComposablePipelines

/// Builds its loop in `body`, so every lowering makes a new one.
private struct BuiltInBody: Pipeline {
    typealias Output = String

    var body: some Pipeline {
        AgentLoop(task: "t", tools: [], systemPrompt: "p")
    }
}

/// Stores its loop but applies a modifier to it in `body`.
private struct ModifiedInBody: Pipeline {
    typealias Output = String

    let loop = AgentLoop(task: "t", tools: [], systemPrompt: "p")

    var body: some Pipeline {
        loop.answerOnLastTurn()
    }
}

/// Builds its loop, with its modifiers, in `init` and stores it.
private struct Stored: Pipeline {
    typealias Output = String

    let loop: AgentLoop

    init() {
        loop = AgentLoop(task: "t", tools: [], systemPrompt: "p").answerOnLastTurn()
    }

    var body: some Pipeline {
        loop
    }
}

/// A loop created while a body is lowered traps instead of starting over every turn.
@Test func agentLoopBuiltInsideABodyTraps() async {
    await #expect(processExitsWith: .failure) {
        _ = BuiltInBody().loweredGraph()
    }
}

/// A stop policy added while a body is lowered traps too: the policy would be new every turn.
@Test func modifierAppliedInsideABodyTraps() async {
    await #expect(processExitsWith: .failure) {
        _ = ModifiedInBody().loweredGraph()
    }
}

/// A loop stored with its modifiers, built outside lowering, lowers.
@Test func storedLoopLowers() {
    _ = Stored().loweredGraph()
}
#endif
