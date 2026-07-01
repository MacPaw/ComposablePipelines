//
//  CodingTools.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines

// Coding tools for the agent harness. Every tool is confined to a `PathJail` and returns a
// readable `String` — including "error: …" for expected failures — so the model can recover
// within the loop instead of aborting the run.

private let maxToolOutput = 16_000

private func clamp(_ text: String) -> String {
    guard text.count > maxToolOutput else { return text }
    return String(text.prefix(maxToolOutput)) + "\n…[truncated]"
}

/// Read a UTF-8 text file.
public struct ReadFileTool: ModelTool {
    public struct Input: Codable, Sendable { public let path: String }
    public typealias Output = String
    public static let name = "read_file"
    public static let description = "Read a UTF-8 text file relative to the working directory. Input: {path}."
    public static let inputSchema: JSONSchema = .object(properties: ["path": .string], required: ["path"])

    let jail: PathJail
    public init(jail: PathJail) { self.jail = jail }

    public func call(_ input: Input) async throws -> String {
        guard let url = try? jail.resolve(input.path) else {
            return "error: path '\(input.path)' escapes the working directory"
        }
        guard let data = try? Data(contentsOf: url) else {
            return "error: cannot read '\(input.path)'"
        }
        return clamp(String(decoding: data, as: UTF8.self))
    }
}

/// List the entries of a directory (directories marked with a trailing slash).
public struct ListDirTool: ModelTool {
    public struct Input: Codable, Sendable { public let path: String? }
    public typealias Output = String
    public static let name = "list_dir"
    public static let description = "List entries of a directory relative to the working directory. Input: {path} (defaults to \".\")."
    public static let inputSchema: JSONSchema = .object(properties: ["path": .string], required: [])

    let jail: PathJail
    public init(jail: PathJail) { self.jail = jail }

    public func call(_ input: Input) async throws -> String {
        let path = input.path ?? "."
        guard let url = try? jail.resolve(path) else {
            return "error: path '\(path)' escapes the working directory"
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return "error: cannot list '\(path)'"
        }
        let lines = entries
            .map { entry -> String in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return entry.lastPathComponent + (isDir ? "/" : "")
            }
            .sorted()
        return lines.isEmpty ? "(empty)" : clamp(lines.joined(separator: "\n"))
    }
}

/// Search files under a directory for a literal, case-insensitive substring.
public struct GrepTool: ModelTool {
    public struct Input: Codable, Sendable { public let pattern: String; public let path: String? }
    public typealias Output = String
    public static let name = "grep"
    public static let description = "Search files for a literal (case-insensitive) substring. Input: {pattern, path?}. Returns matching 'file:line: text' lines."
    public static let inputSchema: JSONSchema = .object(
        properties: ["pattern": .string, "path": .string], required: ["pattern"])

    let jail: PathJail
    public init(jail: PathJail) { self.jail = jail }

    public func call(_ input: Input) async throws -> String {
        let path = input.path ?? "."
        guard let root = try? jail.resolve(path) else {
            return "error: path '\(path)' escapes the working directory"
        }
        let skip: Set<String> = [".git", ".build", ".swiftpm", "node_modules"]
        let maxMatches = 80
        var matches: [String] = []

        let urls: [URL]
        if (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey])
            var collected: [URL] = []
            while let url = enumerator?.nextObject() as? URL {
                if url.pathComponents.contains(where: skip.contains) { enumerator?.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    collected.append(url)
                }
            }
            urls = collected
        } else {
            urls = [root]
        }

        outer: for url in urls {
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000 else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.localizedCaseInsensitiveContains(input.pattern) {
                    matches.append("\(jail.display(url)):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    if matches.count >= maxMatches { break outer }
                }
            }
        }
        return matches.isEmpty ? "no matches" : clamp(matches.joined(separator: "\n"))
    }
}

/// Write (overwriting) a UTF-8 text file, creating parent directories.
public struct WriteFileTool: ModelTool {
    public struct Input: Codable, Sendable { public let path: String; public let content: String }
    public typealias Output = String
    public static let name = "write_file"
    public static let description = "Write (overwrite) a UTF-8 text file, creating parent directories. Input: {path, content}."
    public static let inputSchema: JSONSchema = .object(
        properties: ["path": .string, "content": .string], required: ["path", "content"])

    let jail: PathJail
    public init(jail: PathJail) { self.jail = jail }

    public func call(_ input: Input) async throws -> String {
        guard let url = try? jail.resolve(input.path) else {
            return "error: path '\(input.path)' escapes the working directory"
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(input.content.utf8).write(to: url)
            return "wrote \(jail.display(url)) (\(input.content.utf8.count) bytes)"
        } catch {
            return "error: cannot write '\(input.path)': \(error.localizedDescription)"
        }
    }
}

/// Replace a single, unique literal occurrence in a file.
public struct EditFileTool: ModelTool {
    public struct Input: Codable, Sendable {
        public let path: String
        public let old_string: String
        public let new_string: String
    }
    public typealias Output = String
    public static let name = "edit_file"
    public static let description = "Replace one exact, unique occurrence of old_string with new_string in a file. Input: {path, old_string, new_string}."
    public static let inputSchema: JSONSchema = .object(
        properties: ["path": .string, "old_string": .string, "new_string": .string],
        required: ["path", "old_string", "new_string"])

    let jail: PathJail
    public init(jail: PathJail) { self.jail = jail }

    public func call(_ input: Input) async throws -> String {
        guard let url = try? jail.resolve(input.path) else {
            return "error: path '\(input.path)' escapes the working directory"
        }
        guard let data = try? Data(contentsOf: url) else {
            return "error: cannot read '\(input.path)'"
        }
        let text = String(decoding: data, as: UTF8.self)
        let occurrences = text.components(separatedBy: input.old_string).count - 1
        switch occurrences {
        case 0: return "error: old_string not found in '\(input.path)'"
        case 1:
            let updated = text.replacingOccurrences(of: input.old_string, with: input.new_string)
            do {
                try Data(updated.utf8).write(to: url)
                return "edited \(jail.display(url))"
            } catch {
                return "error: cannot write '\(input.path)': \(error.localizedDescription)"
            }
        default:
            return "error: old_string is ambiguous in '\(input.path)' (\(occurrences) occurrences); include more context"
        }
    }
}

/// Run a shell command with the working directory as cwd.
///
/// - Important: `bash` is the agent's one escape hatch — unlike the file tools, it is **not**
///   confined by `PathJail`. Setting `currentDirectoryURL` only changes cwd; the command itself
///   can read, write, or reach the network anywhere the host user can. Use the agent only on a
///   scratch/throwaway directory and a model you trust. To harden, run the process inside an OS
///   sandbox (`sandbox-exec` on macOS, bubblewrap/landlock on Linux), gate it behind an allowlist
///   or per-command approval, or drop `BashTool` from ``defaultCodingTools(jail:)``.
public struct BashTool: ModelTool {
    public struct Input: Codable, Sendable { public let command: String }
    public typealias Output = String
    public static let name = "bash"
    public static let description = "Run a shell command in the working directory. Input: {command}. Returns exit code and combined stdout/stderr."
    public static let inputSchema: JSONSchema = .object(properties: ["command": .string], required: ["command"])

    let jail: PathJail
    public init(jail: PathJail) { self.jail = jail }

    public func call(_ input: Input) async throws -> String {
        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", input.command]
        process.currentDirectoryURL = jail.root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "error: cannot run command: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return "exit \(process.terminationStatus)\n" + clamp(output)
        #else
        return "error: bash is not available on this platform"
        #endif
    }
}

/// The default coding-agent tool set, all confined to `jail`.
public func defaultCodingTools(jail: PathJail) -> [any ModelTool] {
    [
        ReadFileTool(jail: jail),
        ListDirTool(jail: jail),
        GrepTool(jail: jail),
        WriteFileTool(jail: jail),
        EditFileTool(jail: jail),
        BashTool(jail: jail),
    ]
}
