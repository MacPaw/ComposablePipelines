//
//  Main.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines
import CodingAgent
import OpenAIExecutor

@main
enum CPAgent {
    static func main() async {
        let theme = Theme()
        let console = Console(theme: theme)

        // Args: [dir] [task...]. The first token is the working dir only if it's an existing
        // directory; otherwise everything is treated as an initial task and dir defaults to cwd.
        var rest = Array(CommandLine.arguments.dropFirst())
        var dirPath = "."
        if let first = rest.first, isDirectory(first) {
            dirPath = first
            rest.removeFirst()
        }
        let initialTask = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        let dir = URL(fileURLWithPath: dirPath)
        guard isDirectory(dir.path) else {
            console.note("'\(dirPath)' is not a directory")
            exit(1)
        }

        let config: OpenAIChatExecutor.Config
        do {
            config = try OpenAIChatExecutor.Config.fromEnvironment()
        } catch OpenAIChatExecutorError.missingAPIKey {
            console.note("set OPENAI_API_KEY (use any value for tokenless local servers)")
            exit(1)
        } catch {
            console.note("\(error)")
            exit(1)
        }

        let jail = PathJail(root: dir)
        // The one line to change to swap in a different agent.
        let agent: any ChatAgent = CodingAgentAdapter(
            executor: OpenAIChatExecutor(config: config), jail: jail)

        console.banner(agent: agent.name, model: config.model, dir: jail.root.path)

        if !initialTask.isEmpty {
            console.userEcho(initialTask)
            await run(initialTask, agent: agent, console: console)
        }

        while true {
            FileHandle.standardOutput.write(Data(console.promptPrefix().utf8))
            guard let raw = readLine(strippingNewline: true) else { break }
            let message = raw.trimmingCharacters(in: .whitespaces)
            if message.isEmpty { continue }
            if ["exit", "quit", ":q"].contains(message.lowercased()) { break }
            console.userEcho(message)
            await run(message, agent: agent, console: console)
        }
        console.goodbye()
    }

    /// Run one message, animating the spinner while the agent works.
    private static func run(_ message: String, agent: any ChatAgent, console: Console) async {
        let spinner = Task {
            while !Task.isCancelled {
                console.tick()
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
        defer { spinner.cancel() }
        do {
            let reply = try await agent.send(message) { event in
                switch event {
                case .thinking:
                    console.thinking()
                case .reasoning(let text):
                    console.reasoning(text)
                case .toolCall(let name, let arguments):
                    console.toolCall(name: name, arguments: arguments)
                }
            }
            console.answer(reply)
        } catch {
            console.note("error: \(error)")
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
