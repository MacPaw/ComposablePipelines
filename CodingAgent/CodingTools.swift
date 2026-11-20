//
//  CodingTools.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
import ComposablePipelines
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// Outcome of a bounded shell run.
public struct ShellResult: Sendable {
    public let exitCode: Int32   // process exit status, or -1 when it was killed on timeout
    public let output: String    // combined stdout/stderr
    public let timedOut: Bool
}

/// Run a shell command with a wall-clock timeout, its own process group, and off-thread
/// output capture.
///
/// Why not `readDataToEndOfFile()` + `waitUntilExit()`: that read only returns once *every*
/// write end of the pipe closes. A command that backgrounds a daemon (`node server.js &`,
/// `foo &`) leaves that daemon holding the pipe, so the read — and the runner — hangs forever.
/// Here the child leads its own process group, output is drained on a background thread, and:
///   - if the command overruns `timeout`, the whole group is SIGKILLed; and
///   - once the shell exits, any lingering group members (detached daemons) are reaped after a
///     short grace period so the pipe closes and we return promptly.
#if os(macOS) || os(Linux)
public func runShell(
    executable: String, arguments: [String], cwd: URL, timeout: TimeInterval
) -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice  // never block reading stdin

    // Drain output off-thread so a full pipe can't wedge the child, and so we can stop
    // waiting on our own schedule even if a detached grandchild still holds the pipe.
    let lock = NSLock()
    var collected = Data()
    let readerDone = DispatchSemaphore(value: 0)
    let readHandle = pipe.fileHandleForReading
    DispatchQueue.global(qos: .utility).async {
        let d = readHandle.readDataToEndOfFile()
        lock.lock(); collected = d; lock.unlock()
        readerDone.signal()
    }

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        return ShellResult(exitCode: 126,
                           output: "error: cannot run command: \(error.localizedDescription)",
                           timedOut: false)
    }
    // Put the child (and jobs it starts) in its own group so we can kill the whole tree.
    // If it lost the race and already exited, this fails harmlessly (no such group).
    let pid = process.processIdentifier
    _ = setpgid(pid, pid)

    // Bound the shell's own runtime. `sleep 999` (foreground hang) is caught here.
    let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
    if timedOut {
        kill(-pid, SIGKILL)
        _ = exited.wait(timeout: .now() + 2)
    }
    // Shell has exited or been killed. Give the reader a moment to drain; if a detached
    // daemon still holds the pipe open, kill the group to release it (the `node &` case).
    if readerDone.wait(timeout: .now() + 1) == .timedOut {
        kill(-pid, SIGKILL)
        readerDone.wait()
    }

    lock.lock(); let data = collected; lock.unlock()
    let text = String(decoding: data, as: UTF8.self)
    if timedOut {
        return ShellResult(exitCode: -1,
                           output: text + "\n…[killed: exceeded \(Int(timeout))s timeout]",
                           timedOut: true)
    }
    return ShellResult(exitCode: process.terminationStatus, output: text, timedOut: false)
}
#endif

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
    let timeout: TimeInterval
    public init(jail: PathJail, timeout: TimeInterval = 120) {
        self.jail = jail
        self.timeout = timeout
    }

    public func call(_ input: Input) async throws -> String {
        #if os(macOS) || os(Linux)
        let r = runShell(executable: "/bin/zsh", arguments: ["-c", input.command],
                         cwd: jail.root, timeout: timeout)
        return "exit \(r.exitCode)\n" + clamp(r.output)
        #else
        return "error: bash is not available on this platform"
        #endif
    }
}

// MARK: - Research tools (web, GitHub, arXiv)

private func httpGet(_ urlString: String, headers: [String: String] = [:], timeout: TimeInterval = 25) async -> String? {
    guard let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    do {
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(decoding: data, as: UTF8.self)
    } catch { return nil }
}

private func firstMatches(_ pattern: String, in text: String, group: Int = 1, limit: Int = 20) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
    let ns = text as NSString
    var out: [String] = []
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if m.numberOfRanges > group, m.range(at: group).location != NSNotFound {
            out.append(ns.substring(with: m.range(at: group)))
            if out.count >= limit { break }
        }
    }
    return out
}

private func stripHTML(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (e, c) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&nbsp;": " "] {
        t = t.replacingOccurrences(of: e, with: c)
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Search the web. Uses Jina's search API (`s.jina.ai`) when `JINA_API_KEY` is set in the
/// environment — higher-quality, structured results — and otherwise falls back to DuckDuckGo's
/// keyless HTML endpoint. The key is read from the environment (never embedded in source).
public struct WebSearchTool: ModelTool {
    public struct Input: Codable, Sendable { public let query: String }
    public typealias Output = String
    public static let name = "web_search"
    public static let description = "Search the web. Input: {query}. Returns the top results as 'title — url — snippet'. Use gh for GitHub code and arxiv_search for papers."
    public static let inputSchema: JSONSchema = .object(properties: ["query": .string], required: ["query"])
    public init() {}

    public func call(_ input: Input) async throws -> String {
        let q = input.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let key = ProcessInfo.processInfo.environment["JINA_API_KEY"], !key.isEmpty {
            if let result = await Self.jinaSearch(query: q, key: key) { return result }
            // Jina failed (network/quota) — fall through to the keyless engine rather than erroring.
        }
        return await Self.duckDuckGo(query: q, rawQuery: input.query)
    }

    /// Jina search API. `X-Respond-With: no-content` keeps the payload to SERP metadata (title,
    /// url, description) instead of every page's full text, and `Accept: application/json` gives
    /// a structured response we can parse deterministically.
    private static func jinaSearch(query q: String, key: String) async -> String? {
        guard let raw = await httpGet(
            "https://s.jina.ai/?q=\(q)",
            headers: [
                "Authorization": "Bearer \(key)",
                "Accept": "application/json",
                "X-Respond-With": "no-content",
            ],
            timeout: 30
        ), let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = json["data"] as? [[String: Any]], !items.isEmpty
        else { return nil }

        var lines: [String] = []
        for (i, item) in items.prefix(8).enumerated() {
            let title = (item["title"] as? String) ?? ""
            let url = (item["url"] as? String) ?? ""
            let snip = ((item["description"] as? String) ?? (item["content"] as? String) ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("\(i + 1). \(title) — \(url)\n   \(String(snip.prefix(280)))")
        }
        return clamp(lines.joined(separator: "\n"))
    }

    private static func duckDuckGo(query q: String, rawQuery: String) async -> String {
        guard let html = await httpGet("https://html.duckduckgo.com/html/?q=\(q)",
                                       headers: ["User-Agent": "Mozilla/5.0 (Macintosh) elix-eval-runner"]) else {
            return "error: web search request failed (network/blocked)"
        }
        let hrefs = firstMatches("class=\"result__a\"[^>]*href=\"([^\"]+)\"", in: html, limit: 8)
        let titles = firstMatches("class=\"result__a\"[^>]*>(.*?)</a>", in: html, limit: 8)
        let snips = firstMatches("class=\"result__snippet\"[^>]*>(.*?)</a>", in: html, limit: 8)
        if hrefs.isEmpty { return "no results (search returned nothing parseable for '\(rawQuery)')" }
        var lines: [String] = []
        for i in hrefs.indices {
            var url = hrefs[i].replacingOccurrences(of: "&amp;", with: "&")
            if let r = url.range(of: "uddg="), let dec = String(url[r.upperBound...]).components(separatedBy: "&").first?.removingPercentEncoding {
                url = dec
            }
            let title = i < titles.count ? stripHTML(titles[i]) : ""
            let snip = i < snips.count ? stripHTML(snips[i]) : ""
            lines.append("\(i + 1). \(title) — \(url)\n   \(snip)")
        }
        return clamp(lines.joined(separator: "\n"))
    }
}

/// Read-only GitHub access via the `gh` CLI (uses the host's auth). For researching how a
/// feature works in an open-source project: search code, read files, inspect PRs/issues.
public struct GhTool: ModelTool {
    public struct Input: Codable, Sendable { public let command: String }
    public typealias Output = String
    public static let name = "gh"
    public static let description = "Query GitHub read-only via the gh CLI. Input: {command} = args after `gh`. Read a file's source with \"api repos/OWNER/REPO/contents/PATH\" (returns raw text). Also: \"search code 'QUERY' --repo OWNER/REPO\", \"repo view OWNER/REPO\", \"pr view N --repo OWNER/REPO\". Use the repo's CURRENT owner (projects get renamed, e.g. it's now fastapi/fastapi). Read-only subcommands only."
    public static let inputSchema: JSONSchema = .object(properties: ["command": .string], required: ["command"])

    let jail: PathJail
    public init(jail: PathJail) { self.jail = jail }

    public func call(_ input: Input) async throws -> String {
        #if os(macOS) || os(Linux)
        let raw = input.command.trimmingCharacters(in: .whitespaces)
        // Control characters (newline/CR/tab/…) are a shell-injection vector and never appear in a
        // legitimate gh command — reject them outright.
        if raw.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            return "error: control characters are not allowed in the gh tool"
        }
        // We exec gh directly (no shell) below, so metacharacters cannot chain commands; keep the
        // guard anyway as defense in depth and to reject obviously-hostile input early.
        if raw.contains(where: { ";&|`<>#".contains($0) }) || raw.contains("$(") {
            return "error: shell metacharacters are not allowed in the gh tool"
        }
        // Split into an argv the way a shell would (honoring quotes) so the allow-list is checked
        // against the *parsed* command, not a raw prefix a newline/quote could slip past.
        guard var tokens = Self.tokenize(raw), let sub = tokens.first?.lowercased() else {
            return "error: could not parse the gh command — check your quoting"
        }
        // Read-only subcommands only, matched on parsed tokens.
        let twoWord: Set<String> = ["repo view", "pr view", "pr list", "pr diff",
                                    "issue view", "issue list", "release view", "release list"]
        let verb = tokens.count >= 2 ? "\(sub) \(tokens[1].lowercased())" : sub
        guard sub == "api" || sub == "search" || twoWord.contains(verb) else {
            return "error: only read-only gh subcommands are allowed (api, search, repo view, pr view|list|diff, issue view|list, release view|list)"
        }
        if sub == "api" {
            // Reject write verbs/flags: gh api defaults to GET, so any explicit method/field is a write.
            if tokens.contains(where: { token in
                let l = token.lowercased()
                return l == "-x" || l == "-f"
                    || l.hasPrefix("--method") || l.hasPrefix("--field")
                    || l.hasPrefix("--input") || l.hasPrefix("--silent")
            }) {
                return "error: gh api is restricted to read-only GET requests"
            }
            // `api .../contents/PATH` returns metadata JSON with the file body base64-encoded —
            // unreadable to the model. Request the raw media type so a file comes back as source
            // text (directories still return their JSON listing, unaffected by this header).
            let hasContents = tokens.contains { $0.contains("/contents/") }
            let hasAccept = tokens.contains { $0.lowercased().hasPrefix("accept:") }
            if hasContents && !hasAccept {
                tokens += ["--header", "Accept: application/vnd.github.raw"]
            }
        }
        // Exec gh DIRECTLY — no `zsh -c`, so there is no word-splitting, no glob expansion (the old
        // `noglob` hack is unnecessary), and no way for an argument to chain a second command.
        let r = runShell(executable: "/usr/bin/env", arguments: ["gh"] + tokens, cwd: jail.root, timeout: 60)
        let out = clamp(r.output)
        // gh prints nothing on a zero-result search; surface that instead of a bare "exit 0".
        if r.exitCode == 0 && out.isEmpty {
            return "exit 0\n(no output — the query matched nothing; check the owner/repo is current, "
                + "e.g. a renamed repo, and that code search needs an authenticated gh)"
        }
        return "exit \(r.exitCode)\n" + out
        #else
        return "error: gh is not available on this platform"
        #endif
    }

    /// Split a command line into argv the way a POSIX shell would, honoring single and double quotes
    /// (quotes group and are stripped; whitespace outside quotes separates). Returns nil on an
    /// unterminated quote. No variable/command expansion — we exec directly, so `$…`/backticks are
    /// literal (and already rejected by `call`).
    static func tokenize(_ s: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?  // nil, "'" or "\""
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; hasToken = true
            } else if ch == " " || ch == "\t" {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch); hasToken = true
            }
        }
        if quote != nil { return nil }  // unterminated quote
        if hasToken { tokens.append(current) }
        return tokens
    }
}

/// Search arXiv for scientific papers (keyless Atom API).
public struct ArxivSearchTool: ModelTool {
    public struct Input: Codable, Sendable { public let query: String }
    public typealias Output = String
    public static let name = "arxiv_search"
    public static let description = "Search arXiv for scientific papers. Input: {query}. Returns title, arXiv id/url, published date, and an abstract snippet for the top matches."
    public static let inputSchema: JSONSchema = .object(properties: ["query": .string], required: ["query"])
    public init() {}

    public func call(_ input: Input) async throws -> String {
        let q = input.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let xml = await httpGet("https://export.arxiv.org/api/query?search_query=all:\(q)&start=0&max_results=8&sortBy=relevance") else {
            return "error: arXiv request failed"
        }
        let entries = firstMatches("<entry>(.*?)</entry>", in: xml, limit: 8)
        if entries.isEmpty { return "no arXiv results for '\(input.query)'" }
        var lines: [String] = []
        for (i, e) in entries.enumerated() {
            let title = stripHTML(firstMatches("<title>(.*?)</title>", in: e, limit: 1).first ?? "")
            let id = (firstMatches("<id>(.*?)</id>", in: e, limit: 1).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let pub = (firstMatches("<published>(.*?)</published>", in: e, limit: 1).first ?? "").prefix(10)
            let summary = stripHTML(firstMatches("<summary>(.*?)</summary>", in: e, limit: 1).first ?? "")
            lines.append("\(i + 1). \(title) (\(pub))\n   \(id)\n   \(String(summary.prefix(280)))")
        }
        return clamp(lines.joined(separator: "\n"))
    }
}

/// The default coding-agent tool set, all confined to `jail`. `bashTimeout` bounds each
/// `bash` command; a command that overruns it (or backgrounds a daemon) is killed so a
/// single tool call can't wedge the agent. `research: true` adds web_search / gh / arxiv_search
/// for research-style tasks. `finish` is always included: it is how the agent ends the run — but
/// only where `FinishPolicy` is installed, which `CodingAgentPipeline` does and a plain `AgentLoop`
/// does with `.finishTool()`. Without it a `finish` call answers "finished" and the loop goes on.
public func defaultCodingTools(jail: PathJail, bashTimeout: TimeInterval = 120,
                               research: Bool = true) -> [any ModelTool] {
    var tools: [any ModelTool] = [
        ReadFileTool(jail: jail),
        ListDirTool(jail: jail),
        GrepTool(jail: jail),
        WriteFileTool(jail: jail),
        EditFileTool(jail: jail),
        BashTool(jail: jail, timeout: bashTimeout),
        FinishTool(),
    ]
    if research {
        tools += [WebSearchTool(), GhTool(jail: jail), ArxivSearchTool()]
    }
    return tools
}
