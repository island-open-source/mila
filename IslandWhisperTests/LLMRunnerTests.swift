import XCTest
@testable import IslandWhisper

/// End-to-end-ish tests for `LLMRunner` — we use `/bin/cat` as a stand-in
/// for `claude -p` so we can verify the spawn + pipe behaviour without
/// depending on the user having a real LLM CLI installed.
final class LLMRunnerTests: XCTestCase {

    func test_runner_throws_when_tool_disabled() async {
        do {
            _ = try await LLMRunner.run(tool: .none,
                                        prompt: "anything",
                                        transcript: "hi",
                                        executablePathOverride: nil)
            XCTFail("Expected toolDisabled error")
        } catch let error as LLMRunnerError {
            if case .toolDisabled = error { /* ok */ } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_runner_throws_when_override_path_is_missing() async {
        do {
            _ = try await LLMRunner.run(tool: .claude,
                                        prompt: "anything",
                                        transcript: "hi",
                                        executablePathOverride: "/definitely/not/here/claude")
            XCTFail("Expected executableNotFound error")
        } catch let error as LLMRunnerError {
            if case .executableNotFound = error { /* ok */ } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    /// Regression guard for the "IslandWhisper is trying to access Desktop"
    /// TCC popups. The runner MUST chdir the child to an isolated empty
    /// directory — never the user's $HOME or `/` — because macOS attributes
    /// the child's file access to *our* bundle ID and the user would see
    /// scary prompts for any folder the LLM CLI happens to scan.
    func test_runner_spawns_child_in_isolated_temp_directory() async throws {
        // Script prints its cwd and lists the entries it sees there.
        let script = makeScript("""
            #!/bin/sh
            printf 'cwd=%s\\n' "$PWD"
            printf 'entries=%s\\n' "$(ls -A 2>/dev/null | wc -l | tr -d ' ')"
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let out = try await LLMRunner.run(
            tool: .claude,
            prompt: "x", transcript: "y",
            executablePathOverride: script.path,
            timeout: 5)
        // cwd must NOT be home or root — those would trigger TCC popups.
        XCTAssertFalse(out.contains("cwd=\(NSHomeDirectory())\n"),
                       "Child spawned in $HOME: \(out)")
        XCTAssertFalse(out.contains("cwd=/\n"),
                       "Child spawned in /: \(out)")
        // It SHOULD be empty — proving there's nothing for the LLM to scan.
        XCTAssertTrue(out.contains("entries=0"),
                      "Sandbox directory is not empty: \(out)")
        // And it should be under the temp dir.
        let tempRoot = FileManager.default.temporaryDirectory.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        XCTAssertTrue(out.contains(tempRoot),
                      "Child cwd is not under temporary directory: \(out)")
    }

    /// The transcript travels in argv (via `composedPrompt`), not stdin —
    /// proven by spawning a script that echoes its last argument and
    /// asserting the transcript appears there. We also need to be confident
    /// stdin is closed (no hang).
    func test_runner_passes_prompt_in_argv_and_closes_stdin() async throws {
        let script = makeScript("""
            #!/bin/sh
            # Echo the last argument (= the composed prompt we passed in).
            printf '%s' "${@: -1}"
            # And read stdin to EOF to prove it's already closed (would hang otherwise).
            cat >/dev/null
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let result = try await LLMRunner.run(tool: .claude,
                                             prompt: "Title please",
                                             transcript: "the audio",
                                             executablePathOverride: script.path,
                                             timeout: 5)
        XCTAssertTrue(result.contains("Title please"),
                      "prompt missing from argv: \(result)")
        XCTAssertTrue(result.contains("the audio"),
                      "transcript missing from argv: \(result)")
    }

    private func makeScript(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-whisper-llm-test-\(UUID().uuidString).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    func test_runner_surfaces_nonzero_exit_code() async {
        // `/usr/bin/false` always exits 1.
        do {
            _ = try await LLMRunner.run(tool: .claude,
                                        prompt: "x",
                                        transcript: "y",
                                        executablePathOverride: "/usr/bin/false")
            XCTFail("Expected nonZeroExit error")
        } catch let error as LLMRunnerError {
            if case .nonZeroExit(let code, _) = error {
                XCTAssertEqual(code, 1)
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    /// The wire format MUST keep the transcript inside the prompt argument,
    /// not on stdin — `cursor-agent -p` ignores stdin so anything we expect
    /// it to read has to be in argv.
    func test_composed_prompt_appends_transcript_after_separator() {
        let composed = LLMRunner.composedPrompt(
            "Summarize this.",
            transcript: "Hello world.")
        XCTAssertEqual(composed,
                       "Summarize this.\n\n---\nTranscript:\nHello world.")
    }

    func test_composed_prompt_with_empty_transcript_is_just_the_prompt() {
        let composed = LLMRunner.composedPrompt("Say hi.", transcript: "   ")
        XCTAssertEqual(composed, "Say hi.")
    }

    func test_timeout_fires_when_process_exceeds_limit() async {
        // Script ignores its args and sleeps 5s. Runner times out at 1s.
        let script = makeScript("""
            #!/bin/sh
            sleep 5
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let start = Date()
        do {
            _ = try await LLMRunner.run(tool: .claude,
                                        prompt: "x",
                                        transcript: "y",
                                        executablePathOverride: script.path,
                                        timeout: 1)
            XCTFail("Expected timedOut error")
        } catch let error as LLMRunnerError {
            if case .timedOut = error {
                let elapsed = Date().timeIntervalSince(start)
                XCTAssertLessThan(elapsed, 3.5,
                                  "Timeout fired too late: \(elapsed)s")
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Real-CLI smoke tests
    //
    // These hit the actual `claude` / `cursor-agent` binaries if installed.
    // They auto-skip on machines without the CLIs so CI stays green; on the
    // dev machine they catch the kind of "I shipped a default prompt that
    // hangs claude trying to use a tool it doesn't have" bug that motivated
    // this fix in the first place.

    private func resolve(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func test_claude_cli_returns_a_title_for_a_sample_transcript() async throws {
        guard let claudePath = resolve("claude") else {
            throw XCTSkip("claude CLI not installed on this machine")
        }
        let transcript = "We agreed to migrate the staging ECR to the new account by Friday and Uri will open the PR."
        let result = try await LLMRunner.run(
            tool: .claude,
            prompt: LLMSettings.defaultNamePrompt,
            transcript: transcript,
            executablePathOverride: claudePath,
            timeout: 120
        )
        XCTAssertFalse(result.isEmpty, "claude returned empty output")
        // A title shouldn't be a paragraph. Anything under ~120 chars is a
        // safe upper bound for 3–6 words plus claude's occasional preamble.
        XCTAssertLessThan(result.count, 200,
                          "claude reply looks like prose, not a title: \(result)")
    }

    func test_cursor_cli_returns_a_title_for_a_sample_transcript() async throws {
        guard let cursorPath = resolve("cursor-agent") else {
            throw XCTSkip("cursor-agent CLI not installed on this machine")
        }
        let transcript = "We agreed to migrate the staging ECR to the new account by Friday and Uri will open the PR."
        let result = try await LLMRunner.run(
            tool: .cursor,
            prompt: LLMSettings.defaultNamePrompt,
            transcript: transcript,
            executablePathOverride: cursorPath,
            timeout: 120
        )
        // The regression we're guarding against: cursor-agent ignores stdin.
        // If the runner accidentally went back to piping the transcript via
        // stdin, cursor-agent would respond with "the transcript wasn't
        // included" — assert we got *something else*.
        XCTAssertFalse(result.isEmpty, "cursor-agent returned empty output")
        XCTAssertFalse(result.lowercased().contains("wasn't included"),
                       "cursor-agent never saw the transcript — runner regressed: \(result)")
        XCTAssertFalse(result.lowercased().contains("could you paste"),
                       "cursor-agent never saw the transcript — runner regressed: \(result)")
    }
}
