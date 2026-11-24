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
/// allow-list. These cases exercise the refusals, the final argv and the environment, all decided before
/// any process is spawned — so they run offline, with no `gh` binary or network.
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

    /// gh runs without a shell, so metacharacters are plain text: a `--jq` pipe is allowed and passed as is.
    func testShellMetacharactersArePlainText() throws {
        for cmd in ["api repos/o/r/issues --jq '.[] | .title'", #"search code "a > b; c && d" --repo o/r"#] {
            let tokens = try XCTUnwrap(GhTool.tokenize(cmd), cmd)
            XCTAssertNil(GhTool.refusal(tokens), cmd)
            XCTAssertEqual(GhTool.arguments(for: tokens), tokens, cmd)
        }
    }

    func testRejectsDisallowedSubcommand() async throws {
        let out = try await run("repo delete owner/repo")
        XCTAssertTrue(out.contains("read-only"), out)
    }

    func testRejectsWriteApiRequests() async throws {
        for cmd in ["api --method POST repos/o/r/issues", "api -X DELETE repos/o/r", "api repos/o/r -f a=b",
                    "api repos/o/r/issues --raw-field title=x", "api graphql --raw-field query=mutation{x}",
                    "api repos/o/r/issues --method=POST", "api repos/o/r --input body.json"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("is not allowed with `gh api`"), "\(cmd) → \(out)")
        }
    }

    /// pflag reads a short flag's value glued to it (`-XPOST`) and bundles of short flags (`-iXPOST`);
    /// every such word is refused, whatever letters it holds.
    func testRejectsJoinedShortFlags() async throws {
        for cmd in ["api repos/o/r/issues -XPOST -fbody=x", "api repos/o/r/git/refs/heads/x -XDELETE",
                    "api repos/o/r/issues -Ftitle=@/etc/hosts", "api repos/o/r -iXPOST", "api repos/o/r -X=POST",
                    "pr view 1 -cw", "pr list -L5"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("write each short flag as its own word"), "\(cmd) → \(out)")
        }
    }

    func testJoinedShortFlagErrorSuggestsTheSplitForm() async throws {
        let out = try await run("pr list -L5")
        XCTAssertTrue(out.contains("`-L 5`"), out)
    }

    func testRejectsRequestsThatLeaveGitHub() async throws {
        for cmd in ["api http://127.0.0.1:8080/x", "api https://example.com/x", "api //example.com/x",
                    "api http:example.com", "api repos/o/r --hostname example.com"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("not a URL or host") || out.contains("another host"), "\(cmd) → \(out)")
        }
    }

    func testRejectsGraphQL() async throws {
        let out = try await run("api graphql")
        XCTAssertTrue(out.contains("GraphQL requests are POSTs"), out)
    }

    func testRejectsHeadersOtherThanAccept() async throws {
        let out = try await run(#"api repos/o/r -H "X-HTTP-Method-Override: DELETE""#)
        XCTAssertTrue(out.contains("only an `Accept: …` header"), out)
    }

    func testRejectsApiWithoutExactlyOneEndpoint() async throws {
        for cmd in ["api", "api repos/o/r repos/o/s", "api repos/o/r -q"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("exactly one endpoint") || out.contains("needs a value"), "\(cmd) → \(out)")
        }
    }

    func testRejectsWebOnReadSubcommands() async throws {
        for cmd in ["repo view o/r --web", "pr view 1 -w", "issue list --web", "search code x -w", "pr diff 1 --web"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("opens a browser"), "\(cmd) → \(out)")
        }
    }

    func testRejectsUnknownSearchKind() async throws {
        let out = try await run("search everything x")
        XCTAssertTrue(out.contains("read-only"), out)
    }

    /// A value that starts with `-` is checked as a flag; the error points to the forms gh reads as a value.
    func testLeadingDashValueErrorPointsToTheValueForms() async throws {
        for cmd in [#"pr list -S "-label:wip""#, "pr list --limit -1"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("`--search=-label:wip`") && out.contains("after `--`"), "\(cmd) → \(out)")
        }
    }

    /// pflag takes a `--` right after a flag that needs a value as that value and goes on reading flags
    /// (`gh pr list --search -- --help` prints help), so there the guard keeps checking.
    func testDoubleDashAfterAFlagWordDoesNotEndTheCheck() async throws {
        for cmd in ["pr list --search -- -w", "issue list -R o/r --search -- --web", "pr list --draft -- -w"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("opens a browser"), "\(cmd) → \(out)")
        }
    }

    /// After `--` gh reads every word as an argument, so for `api` those words are still endpoints.
    func testDoubleDashKeepsTheApiEndpointCheck() async throws {
        let url = try await run("api -- http://127.0.0.1:8080/x")
        XCTAssertTrue(url.contains("not a URL or host"), url)
        let extra = try await run("api repos/o/r -- -XPOST")
        XCTAssertTrue(extra.contains("exactly one endpoint"), extra)
    }

    /// The allow-list must not refuse the commands the tool description advertises or common read flags.
    func testAllowsReadOnlyCommands() throws {
        for cmd in [
            "api repos/o/r/contents/README.md",
            #"api repos/o/r/contents/p --header "Accept: application/vnd.github.raw""#,
            "api repos/o/r/issues --paginate --jq .[].title",
            "api repos/o/r --jq=.name -i",
            "api search/code?q=repo:o/r+foo",
            "api /repos/o/r",
            "search code 'QUERY' --repo o/r",
            "search prs --state open -L 5 --json number,title",
            "repo view o/r",
            "pr view 12 --repo o/r --comments",
            "pr list -R o/r -s open -L 5",
            "pr diff 12 -R o/r --name-only",
            "issue view 3 -R o/r --json title,body",
            "issue list -R o/r --label bug",
            "release view v1.0 -R o/r",
            "release list -R o/r --limit 3",
            "pr list -R o/r --search=-label:wip",
            "search issues -- -label:bug",
            "pr view -- 1",
            "api -- repos/o/r",
            "pr list -R o/r --draft -- 5",
            "pr list -R o/r --search=x -- y",
            "pr list --repo=o/r -- 5",
            #"search code "repo:o/r http://x" -R o/r"#,
            #"pr list -R o/r --search "is:open label:bug""#,
            #"issue list -R o/r --label "type:bug""#,
            "pr list -R o/r --json number --jq '{n: .number}'",
            "repo view -b main o/r",
            "repo view o/r --jq=.a/.b/.c",
            "pr view evil.example/o/r/pull/1 -R o/r",
        ] {
            let tokens = try XCTUnwrap(GhTool.tokenize(cmd), cmd)
            XCTAssertNil(GhTool.refusal(tokens), cmd)
        }
    }

    // MARK: - Requests stay on GitHub, local data stays here

    func testRejectsRepoValuesWithAHostOrScheme() async throws {
        for cmd in ["pr view 1 -R evil.host/o/r", "pr view 1 --repo=https://evil.host/o/r",
                    "search code x -R 127.0.0.1:8080/o/r", "issue list -R o", "pr list -R -w"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("takes `OWNER/REPO`"), "\(cmd) → \(out)")
        }
    }

    /// A URL is refused wherever it stands: the guard can't tell an argument from a flag's value.
    func testRejectsUrlWordsOnReadSubcommands() async throws {
        for cmd in ["repo view https://evil.host/o/r", "pr view https://evil.host/o/r/pull/1",
                    "issue view https://evil.host/o/r/issues/1", "pr diff -- https://evil.host/o/r/pull/1",
                    "pr view -c https://evil.host/o/r/pull/1"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("is a URL") && out.contains("`--flag=value`"), "\(cmd) → \(out)")
        }
    }

    /// `repo view` reaches the host of `HOST/O/R` or `git@HOST:O/R` in any bare word, flag values included.
    func testRejectsRepoViewRepositoryWithAHost() async throws {
        for cmd in ["repo view evil.host/o/r", "repo view -b o/r evil.invalid/x/r", "repo view git@evil.host:o/r",
                    "repo view git@evil.host:r"] {
            let out = try await run(cmd)
            XCTAssertTrue(out.contains("takes `OWNER/REPO`"), "\(cmd) → \(out)")
        }
    }

    /// `--jq` filters see gh's environment (`env.X`), so only what gh needs is passed down.
    func testEnvironmentKeepsOnlyWhatGhNeeds() {
        let env = GhTool.environment(from: [
            "PATH": "/usr/bin", "HOME": "/Users/x", "TMPDIR": "/tmp/", "XDG_CONFIG_HOME": "/c",
            "GH_CONFIG_DIR": "/g", "GH_TOKEN": "t", "GITHUB_TOKEN": "t", "JINA_API_KEY": "k", "AWS_SECRET": "s",
        ])
        XCTAssertEqual(Set(env.keys), ["PATH", "HOME", "TMPDIR", "XDG_CONFIG_HOME", "GH_CONFIG_DIR"])
    }

    // MARK: - Final argv

    private func argv(_ command: String) throws -> [String] {
        GhTool.arguments(for: try XCTUnwrap(GhTool.tokenize(command), command))
    }

    /// The raw `Accept` header goes right after `api`, so gh reads it as a flag even after a `--`.
    func testRawAcceptHeaderGoesRightAfterApi() throws {
        let raw = ["--header", "Accept: application/vnd.github.raw"]
        XCTAssertEqual(try argv("api repos/o/r/contents/README.md"),
                       ["api"] + raw + ["repos/o/r/contents/README.md"])
        XCTAssertEqual(try argv("api -- repos/o/r/contents/README.md"),
                       ["api"] + raw + ["--", "repos/o/r/contents/README.md"])
    }

    func testModelsOwnAcceptHeaderWins() throws {
        for cmd in [#"api repos/o/r/contents/p -H "Accept: application/json""#,
                    #"api repos/o/r/contents/p --header "Accept: application/json""#,
                    #"api repos/o/r/contents/p "--header=Accept: application/json""#] {
            let tokens = try XCTUnwrap(GhTool.tokenize(cmd), cmd)
            XCTAssertEqual(GhTool.arguments(for: tokens), tokens, cmd)
        }
    }

    func testArgumentsUnchangedOutsideContents() throws {
        for cmd in ["api repos/o/r/issues", "pr view 1 -R o/r"] {
            let tokens = try XCTUnwrap(GhTool.tokenize(cmd), cmd)
            XCTAssertEqual(GhTool.arguments(for: tokens), tokens, cmd)
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
