//
//  CodingTools.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
/// `environment` replaces the child's environment; nil inherits this process's.
#if os(macOS) || os(Linux)
public func runShell(
    executable: String, arguments: [String], cwd: URL, timeout: TimeInterval,
    environment: [String: String]? = nil
) -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    if let environment { process.environment = environment }
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
    public static let description = "Query GitHub read-only via the gh CLI. Input: {command} = args after `gh`. Read a file's source with \"api repos/OWNER/REPO/contents/PATH\" (returns raw text). Also: \"search code 'QUERY' --repo OWNER/REPO\", \"repo view OWNER/REPO\", \"pr view N --repo OWNER/REPO\". Use the repo's CURRENT owner (projects get renamed, e.g. it's now fastapi/fastapi). Read-only subcommands only; `api` sends GET to a relative API path."
    public static let inputSchema: JSONSchema = .object(properties: ["command": .string], required: ["command"])

    let jail: PathJail
    public init(jail: PathJail) { self.jail = jail }

    public func call(_ input: Input) async throws -> String {
        #if os(macOS) || os(Linux)
        let raw = input.command.trimmingCharacters(in: .whitespaces)
        // Control characters (newline/CR/tab/…) never appear in a legitimate gh command.
        if raw.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            return "error: control characters are not allowed in the gh tool"
        }
        // Split into an argv the way a shell would (honoring quotes) so the allow-list is checked
        // against the *parsed* command, not a raw prefix a newline/quote could slip past.
        guard let tokens = Self.tokenize(raw), !tokens.isEmpty else {
            return "error: could not parse the gh command — check your quoting"
        }
        if let refusal = Self.refusal(tokens) { return refusal }
        // Exec gh DIRECTLY — no `zsh -c`, so there is no word-splitting, no glob expansion, and no way
        // for an argument to chain a second command; shell metacharacters are plain text to gh.
        let r = runShell(executable: "/usr/bin/env", arguments: ["gh"] + Self.arguments(for: tokens),
                         cwd: jail.root, timeout: 60,
                         environment: Self.environment(from: ProcessInfo.processInfo.environment))
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

    /// The argv gh runs with for an allowed command. `api .../contents/PATH` returns metadata JSON with the
    /// file body base64-encoded — unreadable to the model — so unless the model set its own `Accept`
    /// header (the only header ``refusal(_:)`` allows), the raw media type is asked for and a file comes
    /// back as source text; a directory still returns its JSON listing. The header goes right after
    /// `api`, where gh reads it as a flag even when the endpoint follows a `--`.
    static func arguments(for tokens: [String]) -> [String] {
        guard tokens.first?.lowercased() == "api", tokens.contains(where: { $0.contains("/contents/") }),
              !tokens.contains(where: { $0 == "-H" || $0 == "--header" || $0.hasPrefix("--header=") })
        else { return tokens }
        var arguments = tokens
        arguments.insert(contentsOf: ["--header", "Accept: application/vnd.github.raw"], at: 1)
        return arguments
    }

    /// The environment gh runs with: only what it needs to find itself, its config and its login
    /// (`gh auth login` keeps the token in the keyring or gh's config). Nothing else is passed down,
    /// because `--jq` filters see gh's environment (`env`, `$ENV`): API keys and tokens, `GH_TOKEN`
    /// included, would come back to the model.
    static func environment(from environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            ["PATH", "HOME", "TMPDIR", "GH_CONFIG_DIR"].contains(key) || key.hasPrefix("XDG_")
        }
    }

    /// The read-only subcommands besides `api`.
    static let readSubcommands: Set<String> = [
        "repo view", "pr view", "pr list", "pr diff", "issue view", "issue list", "release view", "release list",
        "search code", "search repos", "search issues", "search prs", "search commits",
    ]

    /// Every flag the `--help` of a ``readSubcommands`` entry lists (gh 2.102.0), except `-w`/`--web`.
    /// One set for all of them: none of these subcommands has a flag that writes or reads local files,
    /// so a flag is harmless wherever it appears; gh itself rejects one its subcommand doesn't know.
    static let readFlags: Set<String> = [
        "-A", "-a", "-B", "-b", "-c", "-d", "-e", "-H", "-L", "-l", "-m", "-O", "-q", "-R", "-S", "-s", "-t",
        "--allow-escape-sequences", "--app", "--archived", "--assignee", "--author", "--author-date",
        "--author-email", "--author-name", "--base", "--branch", "--checks", "--closed", "--color",
        "--commenter", "--comments", "--committer", "--committer-date", "--committer-email",
        "--committer-name", "--created", "--draft", "--exclude", "--exclude-drafts",
        "--exclude-pre-releases", "--extension", "--filename", "--followers", "--forks",
        "--good-first-issues", "--hash", "--head", "--help", "--help-wanted-issues", "--include-forks",
        "--include-prs", "--interactions", "--involves", "--jq", "--json", "--label", "--language",
        "--license", "--limit", "--locked", "--match", "--mention", "--mentions", "--merge", "--merged",
        "--merged-at", "--milestone", "--name-only", "--no-assignee", "--no-label", "--no-milestone",
        "--no-project", "--number-topics", "--order", "--owner", "--parent", "--patch", "--project",
        "--reactions", "--repo", "--review", "--review-requested", "--reviewed-by", "--search",
        "--search-type", "--size", "--sort", "--stars", "--state", "--team-mentions", "--template",
        "--topic", "--tree", "--type", "--updated", "--visibility",
    ]

    /// The `gh api` flags that only shape the output or the `Accept` header, split by whether they take
    /// the next word as their value. Anything else — `-X`, fields, `--input`, `--hostname` — is refused.
    static let apiValueFlags: Set<String> = ["-H", "--header", "-q", "--jq", "-t", "--template",
                                             "-p", "--preview", "--cache"]
    static let apiSwitches: Set<String> = ["-i", "--include", "--paginate", "--slurp", "--silent"]
    private static let apiAllowedList =
        "-H/--header (Accept only), -q/--jq, -t/--template, -p/--preview, --cache, -i/--include, --paginate, --slurp, --silent"

    /// Why a flag is refused, for the flags a model is likely to try.
    private static let refusalReasons: [String: String] = [
        "-X": "gh api only sends GET, so the method cannot be set",
        "--method": "gh api only sends GET, so the method cannot be set",
        "-f": "a field turns the request into a POST",
        "--raw-field": "a field turns the request into a POST",
        "-F": "a field turns the request into a POST, and `@path` would send a local file",
        "--field": "a field turns the request into a POST, and `@path` would send a local file",
        "--input": "it sends a local file as the request body",
        "--hostname": "it sends the request to another host",
        "--verbose": "it prints the full HTTP exchange; leave it out",
        "-w": "it opens a browser on this machine instead of returning text",
        "--web": "it opens a browser on this machine instead of returning text",
    ]

    /// Why `tokens` (the argv after `gh`) may not run, or nil when it may. Fails closed: a flag passes
    /// only when its subcommand's list names it, and a short flag must be a word of its own, because
    /// gh (pflag) also reads `-XPOST`, `-iXPOST` and `-X=POST` as `-X`. Requests go to GitHub only: `api`
    /// sends a GET with no body to a relative API path, and the read subcommands take `-R OWNER/REPO`,
    /// no word with a URL scheme, and in `repo view` no repository with a host. With
    /// ``environment(from:)`` that keeps local data on this machine.
    ///
    /// pflag ends the flags at a `--` only where a flag can start: right after a flag that still needs
    /// its value, the `--` is that value and flags go on. The guard knows which `api` flags take a value
    /// but not which read-subcommand flags do, so there a `--` after a bare flag word does not end the
    /// check. Words after a `--` that does are gh's arguments; for `api` they are still endpoints.
    static func refusal(_ tokens: [String]) -> String? {
        let sub = tokens.first?.lowercased() ?? ""
        let verb = tokens.prefix(2).map { $0.lowercased() }.joined(separator: " ")
        let isAPI = sub == "api"
        guard isAPI || readSubcommands.contains(verb) else {
            return "error: only read-only gh subcommands are allowed: api, search code|repos|issues|prs|commits, "
                + "repo view, pr view|list|diff, issue view|list, release view|list"
        }
        let command = isAPI ? "gh api" : "gh \(verb)"
        let args = tokens.dropFirst(isAPI ? 1 : 2)
        var positionals: [String] = []
        var index = args.startIndex
        while index < args.endIndex {
            let token = args[index]
            index += 1
            guard token.hasPrefix("-"), token != "-" else { positionals.append(token); continue }
            if token == "--" {
                let previous = index - 2 >= args.startIndex ? args[index - 2] : ""
                let flagMayTakeIt = !isAPI && previous.hasPrefix("-") && previous != "-" && !previous.contains("=")
                if flagMayTakeIt { continue }
                positionals += args[index...]
                break
            }
            let valueHint = "If `\(token)` is the value of the previous flag, write that flag as `--flag=value` "
                + (isAPI ? "(e.g. `--jq=…`)" : "(e.g. `--search=-label:wip`)")
                + "; put plain arguments that start with `-` after `--`."
            let name: String
            var inlineValue: String?
            if token.hasPrefix("--") {
                let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                name = String(parts[0])
                inlineValue = parts.count == 2 ? String(parts[1]) : nil
            } else if token.count == 2 {
                name = token
            } else {
                let flag = String(token.prefix(2))
                var rest = token.dropFirst(2)
                if rest.hasPrefix("=") { rest = rest.dropFirst() }
                return "error: `\(token)` reads as the short flag `\(flag)` joined with more text. If it is a flag, "
                    + "write each short flag as its own word and its value as the next word (`\(flag) \(rest)`, "
                    + "not `\(token)`; `-c -q`, not `-cq`). \(valueHint)"
            }
            let allowed = isAPI ? apiValueFlags.contains(name) || apiSwitches.contains(name) : readFlags.contains(name)
            guard allowed else {
                let reason = refusalReasons[name] ?? "it is not on the tool's read-only list"
                let options = isAPI ? "Allowed flags for gh api: \(apiAllowedList)."
                    : "Any flag `\(command) --help` lists is allowed except -w/--web."
                let hint = token.hasPrefix("--") || refusalReasons[name] != nil ? "" : " \(valueHint)"
                return "error: `\(name)` is not allowed with `\(command)`: \(reason). \(options)\(hint)"
            }
            let isRepo = name == "-R" || name == "--repo"
            guard isAPI ? apiValueFlags.contains(name) : isRepo else { continue }
            let value: String
            if let inlineValue {
                value = inlineValue
            } else if index < args.endIndex {
                value = args[index]
                index += 1
            } else {
                return "error: `\(name)` needs a value after it"
            }
            if name == "-H" || name == "--header",
               !value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("accept:") {
                return "error: gh api allows only an `Accept: …` header (e.g. `-H \"Accept: application/vnd.github.raw\"`)"
            }
            if isRepo, !isOwnerRepo(value) {
                return "error: `\(name)` takes `OWNER/REPO`, not `\(value)`: a host or URL would send the request "
                    + "somewhere other than GitHub"
            }
        }
        guard isAPI else {
            // Outside `api` a bare word may be an argument or a flag's value; the guard can't tell which,
            // so it judges the word by what it holds. A host is reached only through a URL with a scheme,
            // or, in `repo view`, a repository written with a host (`HOST/O/R`, `git@HOST:O/R`).
            let valueHint = "If it is the value of the previous flag, write that flag as `--flag=value`."
            if sub == "search" { return nil }
            if let url = positionals.first(where: { $0.contains("://") }) {
                return "error: `\(url)` is a URL, which would send the request to its host; `\(command)` takes "
                    + "a number, branch or tag, with `-R OWNER/REPO` for the repository. \(valueHint)"
            }
            if verb == "repo view",
               let repo = positionals.first(where: { ($0.contains("/") || $0.contains(":")) && !isOwnerRepo($0) }) {
                return "error: `gh repo view` takes `OWNER/REPO`, not `\(repo)`: a host would send the request "
                    + "somewhere other than GitHub. \(valueHint)"
            }
            return nil
        }
        guard positionals.count == 1, let endpoint = positionals.first else {
            return "error: gh api takes exactly one endpoint, e.g. `api repos/OWNER/REPO/contents/PATH` "
                + "(got \(positionals.count))"
        }
        let path = endpoint.prefix { $0 != "?" }
        if path.contains(":") || path.hasPrefix("//") {
            return "error: gh api takes a relative GitHub API path such as `repos/OWNER/REPO`, not a URL or host"
        }
        if endpoint.lowercased() == "graphql" {
            return "error: gh api graphql is not allowed: GraphQL requests are POSTs. Use a REST path such as `repos/OWNER/REPO`"
        }
        return nil
    }

    /// `OWNER/REPO` with no host in front and no URL scheme.
    static func isOwnerRepo(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !value.contains(":")
    }

    /// Split a command line into argv the way a POSIX shell would, honoring single and double quotes
    /// (quotes group and are stripped; whitespace outside quotes separates). Returns nil on an
    /// unterminated quote. No variable/command expansion — we exec directly, so `$…`/backticks are
    /// literal.
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
