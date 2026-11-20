//
//  GhToolTests.swift
//  ComposablePipelines
//
//  Copyright © 2026 MacPaw Inc. All rights reserved.
//  Licensed under the Apache License, Version 2.0 (see LICENSE).
//

import XCTest
@testable import CodingAgent

/// The `gh` tool execs `gh` directly (no shell), and validates the *parsed* argv against a read-only
/// allow-list. These cases exercise the rejection paths, which return before any process is spawned —
/// so they run offline, with no `gh` binary or network.
final class GhToolSafetyTests: XCTestCase {
    private var jail: PathJail!
    override func setUpWithError() throws {
        jail = PathJail(root: FileManager.default.temporaryDirectory)
    }

    private func run(_ command: String) async throws -> String {
        try await GhTool(jail: jail).call(.init(command: command))
    }

    func testRejectsNewlineInjection() async throws {
        // The historic bypass: allow-listed prefix + a newline smuggling a second command.
        let out = try await run("repo view foo\ncat /etc/passwd")
        XCTAssertTrue(out.contains("control characters"), out)
    }

    func testRejectsShellMetacharacters() async throws {
        for cmd in ["repo view x; rm -rf /", "repo view x > /tmp/y", "repo view x && id"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("shell metacharacters"), "\(cmd) → \(out)")
        }
    }

    func testRejectsDisallowedSubcommand() async throws {
        let out = try await run("repo delete owner/repo")
        XCTAssertTrue(out.contains("read-only"), out)
    }

    func testRejectsWriteApiRequests() async throws {
        for cmd in ["api --method POST repos/o/r/issues", "api -X DELETE repos/o/r", "api repos/o/r -f a=b"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("read-only GET"), "\(cmd) → \(out)")
        }
    }

    func testRejectsUnterminatedQuote() async throws {
        let out = try await run(#"search code "unterminated"#)
        XCTAssertTrue(out.contains("could not parse"), out)
    }

    // MARK: - Tokenizer

    func testTokenize_honorsQuotesAndSplitsOnWhitespace() {
        let tokens = GhTool.tokenize(#"api "repos/o/r/contents/p" --header "Accept: application/vnd.github.raw""#)
        XCTAssertEqual(tokens, ["api", "repos/o/r/contents/p", "--header", "Accept: application/vnd.github.raw"])
    }

    func testTokenize_unterminatedQuoteIsNil() {
        XCTAssertNil(GhTool.tokenize(#"search code "oops"#))
    }
}
