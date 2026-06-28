import Foundation

/// Errors surfaced from the CLI invocation. The Settings UI / rename sheet
/// renders `errorDescription` directly so users can self-diagnose path /
/// permission issues without reading logs.
enum LLMRunnerError: LocalizedError {
    case toolDisabled
    case executableNotFound(String)
    case launchFailed(Error)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut(seconds: Int)
    case emptyOutput
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolDisabled:
            return "No LLM is configured in Settings → LLM."
        case .executableNotFound(let name):
            return "Could not find \(name) on PATH. Install it or set the full path in Settings → LLM."
        case .launchFailed(let err):
            return "Could not launch the LLM CLI: \(err.localizedDescription)"
        case .nonZeroExit(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "LLM CLI exited with status \(code). \(trimmed)"
        case .timedOut(let seconds):
            return "LLM CLI did not respond within \(seconds)s. If it's running an agentic task (e.g. calendar lookup), raise the timeout in Settings → LLM."
        case .emptyOutput:
            return "LLM CLI returned no output. Check the prompt or your CLI's auth."
        case .cancelled:
            return "LLM call was cancelled."
        }
    }
}

/// Everything the Settings → LLM test panel needs to explain a run to the
/// user. Produced by `LLMRunner.diagnose`. Unlike `LLMRunner.run`, nothing is
/// thrown away on failure: the user sees the exact command, the exit code, and
/// both streams so they can self-diagnose (or re-run `command` in a terminal).
struct LLMTestResult: Equatable {
    /// The exact, shell-quoted command line that was launched (or would have
    /// been, if we got far enough to build it). Empty when no tool/executable
    /// was resolved.
    var command: String = ""
    /// True only when the CLI launched and exited 0.
    var succeeded: Bool = false
    /// Process exit code, or nil when the CLI never launched (setup error).
    var exitCode: Int32? = nil
    var stdout: String = ""
    var stderr: String = ""
    var durationSeconds: TimeInterval = 0
    /// Set when something prevented the CLI from even running — no tool
    /// selected, executable not on PATH, launch failure.
    var setupError: String? = nil
    var timedOut: Bool = false

    /// Whether anything actually ran. False for pure setup failures.
    var didLaunch: Bool { exitCode != nil }
}

/// Spawns the configured `claude` or `cursor-agent` binary with the user's
/// prompt + transcript and returns whatever the CLI prints to stdout.
///
/// Why the transcript is appended to the *prompt argument* rather than
/// piped on stdin: `claude -p` happens to read both stdin and argv, but
/// `cursor-agent -p` only looks at argv and silently asks "what transcript?"
/// when stdin is closed. Putting the transcript in the prompt is the
/// portable shape that works for both CLIs without the user having to know.
///
/// We deliberately don't try to manage authentication, model selection, or
/// streaming — both CLIs handle that themselves. Our job is "give the user's
/// own LLM the transcript + their prompt, hand back the answer".
enum LLMRunner {
    /// Hard cap on how long we'll wait for a single invocation. Long enough
    /// that an agentic claude run that grinds for a few minutes still gets
    /// to finish — short enough that a truly stuck process doesn't pin the
    /// sheet forever. Foreground "Suggest" callers should pass a smaller
    /// value to keep the UI responsive; background "Send" callers can run
    /// long.
    static let defaultTimeout: TimeInterval = 300

    /// Format the prompt + optional Live-AI summary + transcript into the
    /// single arg-vector blob the CLI sees. Kept as a distinct function so
    /// tests can assert on the exact wire format.
    ///
    /// The summary lives **above** the transcript (and the transcript is
    /// labelled "Full transcript") so the LLM reads the gist before the
    /// raw text — that improves answer quality on long recordings where
    /// the model would otherwise lose the thread halfway through the
    /// transcript. Empty / whitespace-only `summary` is omitted entirely
    /// (we don't want "Summary: (empty)" confusing the model when Live AI
    /// wasn't configured for this recording).
    static func composedPrompt(_ userPrompt: String,
                               transcript: String,
                               summary: String = "") -> String {
        let prompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let gist = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty && gist.isEmpty { return prompt }
        if gist.isEmpty {
            return "\(prompt)\n\n---\nTranscript:\n\(body)"
        }
        if body.isEmpty {
            return "\(prompt)\n\n---\nSummary:\n\(gist)"
        }
        return "\(prompt)\n\n---\nSummary:\n\(gist)\n\nFull transcript:\n\(body)"
    }

    /// Run `tool` with `prompt` + `transcript`. Returns stdout, trimmed.
    /// Throws `LLMRunnerError` on any failure.
    ///
    /// `executablePathOverride` lets the user point at a binary in a
    /// non-PATH location (e.g. `/Users/foo/.local/bin/claude`).
    ///
    /// `summary` (optional) prepends a Live-AI summary section above the
    /// transcript so the LLM has the gist before it reads the raw text.
    /// Pass empty string when there is no summary (e.g. Live AI not
    /// configured) — the wire format collapses to the old transcript-only
    /// shape in that case.
    ///
    /// `extraArgs` are appended verbatim after the tool's standard arguments
    /// — the user's persisted "Extra CLI args" from Settings → LLM (e.g.
    /// `--model …`, a permission flag). Empty for callers that manage their
    /// own args (Live AI pins its own model).
    ///
    /// `timeout` defaults to 5 minutes. Pass a smaller value for foreground
    /// callers that block UI (e.g. the Suggest button).
    static func run(tool: LLMTool,
                    prompt: String,
                    transcript: String,
                    summary: String = "",
                    executablePathOverride: String?,
                    model: String? = nil,
                    session: LLMSession = .none,
                    extraArgs: [String] = [],
                    timeout: TimeInterval = LLMRunner.defaultTimeout) async throws -> String {
        guard tool != .none else { throw LLMRunnerError.toolDisabled }

        let executable = try resolveExecutable(tool: tool,
                                               override: executablePathOverride)
        let fullPrompt = composedPrompt(prompt, transcript: transcript, summary: summary)
        let modelTag = (model?.isEmpty ?? true) ? "(default)" : (model ?? "")
        let sessionTag: String = {
            switch session {
            case .none: return "none"
            case .new(let id): return "new:\(id.uuidString.prefix(8))"
            case .resume(let id): return "resume:\(id.uuidString.prefix(8))"
            }
        }()
        print("LLMRunner: \(executable.lastPathComponent) model=\(modelTag) session=\(sessionTag) prompt=\(fullPrompt.count)c timeout=\(Int(timeout))s")
        // ProcessHandle bridges Swift task cancellation to the underlying
        // `Process`. The continuation thread `attach`es the real Process
        // once it's spawned; if the Task was already cancelled by then
        // (e.g. user hit Cancel between `run(...)` and `Process().run()`),
        // attach immediately terminates the process. Otherwise an actual
        // cancel call on the Task fires `onCancel` below, which terminates
        // the live child.
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // For Live AI's session continuity to work, every tick
                // must share a CWD so claude's per-CWD session
                // storage stays addressable. We key the stable
                // sandbox off the session UUID.
                let sandboxKey: String? = {
                    switch session {
                    case .none: return nil
                    case .new(let id), .resume(let id): return id.uuidString
                    }
                }()
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let outcome = try executeProcess(executable: executable,
                                                         arguments: tool.arguments(prompt: fullPrompt, model: model, session: session) + extraArgs,
                                                         timeout: timeout,
                                                         handle: handle,
                                                         sandboxKey: sandboxKey)
                        // The Swift Task that drove us was cancelled mid-flight
                        // — `handle` SIGTERM'd the process, so the user-visible
                        // truth is "we cancelled it", not "the CLI crashed".
                        if outcome.cancelled {
                            continuation.resume(throwing: LLMRunnerError.cancelled)
                        } else if outcome.timedOut {
                            continuation.resume(throwing: LLMRunnerError.timedOut(seconds: Int(timeout.rounded(.up))))
                        } else if outcome.exitCode != 0 {
                            continuation.resume(throwing: LLMRunnerError.nonZeroExit(
                                code: outcome.exitCode,
                                stderr: outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr))
                        } else {
                            continuation.resume(returning: outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// Run the configured CLI like `run` does, but never throw — capture the
    /// exact command line, exit code, stdout, and stderr and hand them all
    /// back so the Settings → LLM test panel can show the user precisely what
    /// happened. This is the "why isn't my LLM working?" debugging path: the
    /// returned `command` is copy-pasteable into a terminal so the user can
    /// reproduce the run themselves.
    ///
    /// `extraArgs` are appended verbatim after the tool's standard arguments
    /// — the user types them in the test panel (e.g. `--model claude-sonnet-4-6`,
    /// `--debug`) so they can probe param changes without us hardcoding a
    /// model picker. Setup problems (no tool selected, executable not found)
    /// come back in `setupError` rather than as an exception.
    static func diagnose(tool: LLMTool,
                         prompt: String,
                         transcript: String,
                         summary: String = "",
                         extraArgs: [String] = [],
                         executablePathOverride: String?,
                         model: String? = nil,
                         timeout: TimeInterval = 120) async -> LLMTestResult {
        guard tool != .none else {
            return LLMTestResult(setupError: LLMRunnerError.toolDisabled.errorDescription ?? "No LLM configured.")
        }
        let executable: URL
        do {
            executable = try resolveExecutable(tool: tool, override: executablePathOverride)
        } catch {
            let msg = (error as? LLMRunnerError)?.errorDescription ?? error.localizedDescription
            return LLMTestResult(setupError: msg)
        }
        let fullPrompt = composedPrompt(prompt, transcript: transcript, summary: summary)
        let args = tool.arguments(prompt: fullPrompt, model: model) + extraArgs
        let command = ([executable.path] + args).map(shellQuote).joined(separator: " ")
        let start = Date()
        // Bridge Task cancellation to the child process, same as `run` — if
        // the test is cancelled (Settings closed, a newer run started), SIGTERM
        // the CLI instead of leaving it alive until the timeout.
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let elapsed: () -> TimeInterval = { Date().timeIntervalSince(start) }
                    do {
                        let outcome = try executeProcess(executable: executable,
                                                         arguments: args,
                                                         timeout: timeout,
                                                         handle: handle,
                                                         sandboxKey: nil)
                        continuation.resume(returning: LLMTestResult(
                            command: command,
                            succeeded: !outcome.timedOut && outcome.exitCode == 0,
                            exitCode: outcome.exitCode,
                            stdout: outcome.stdout,
                            stderr: outcome.stderr,
                            durationSeconds: elapsed(),
                            timedOut: outcome.timedOut))
                    } catch {
                        // Only `launchFailed` reaches here now.
                        let msg = (error as? LLMRunnerError)?.errorDescription ?? error.localizedDescription
                        continuation.resume(returning: LLMTestResult(
                            command: command,
                            durationSeconds: elapsed(),
                            setupError: msg))
                    }
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// Split a free-text "extra arguments" string into an argv array, honoring
    /// single quotes, double quotes, and backslash escapes the way a POSIX
    /// shell would — so a user can paste `--model "claude sonnet"` and get two
    /// tokens, not three. Deliberately small: it covers the quoting users
    /// actually type, not the full shell grammar.
    static func tokenizeArguments(_ input: String) -> [String] {
        var args: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inSingle {
                if c == "'" { inSingle = false } else { current.append(c) }
            } else if inDouble {
                if c == "\"" {
                    inDouble = false
                } else if c == "\\", i + 1 < chars.count, chars[i + 1] == "\"" || chars[i + 1] == "\\" {
                    i += 1
                    current.append(chars[i])
                } else {
                    current.append(c)
                }
            } else if c == "'" {
                inSingle = true; hasToken = true
            } else if c == "\"" {
                inDouble = true; hasToken = true
            } else if c == "\\", i + 1 < chars.count {
                i += 1
                current.append(chars[i]); hasToken = true
            } else if c == " " || c == "\t" || c == "\n" {
                if hasToken { args.append(current); current = ""; hasToken = false }
            } else {
                current.append(c); hasToken = true
            }
            i += 1
        }
        if hasToken { args.append(current) }
        return args
    }

    /// Quote a single argv token for display so the rendered `command` can be
    /// pasted back into a shell and run as-is. Tokens made only of "safe"
    /// characters are left bare; everything else is single-quoted with any
    /// embedded single quotes escaped the classic `'\''` way.
    static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./=:,@+")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Raw result of a single CLI invocation, before any success/failure
    /// interpretation. `run` maps this onto its throwing contract; `diagnose`
    /// surfaces every field verbatim so the Settings test panel can show the
    /// user exactly what happened (exit code, stdout, stderr) even on failure.
    struct ProcessOutcome {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool
        let cancelled: Bool
    }

    private static func executeProcess(executable: URL,
                                       arguments: [String],
                                       timeout: TimeInterval,
                                       handle: ProcessHandle,
                                       sandboxKey: String? = nil) throws -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        // Inherit `$PATH` etc. so the CLI can find any helpers it shells out
        // to. Spawning a Process from a sandboxed-style minimal environment
        // surprises users whose claude/cursor wrappers source nvm/asdf/etc.
        process.environment = ProcessInfo.processInfo.environment

        // CRITICAL: spawn in a fresh, empty temp directory. macOS attributes
        // any file access by the child process to *our* bundle ID, so if
        // claude / cursor-agent walks the cwd looking for project files
        // (which both do — particularly cursor-agent in `-f` mode), the user
        // sees scary TCC prompts saying "Mila would like to access
        // Desktop / Downloads". Launching from an isolated, empty directory
        // guarantees there's nothing for the LLM CLI to discover and reach
        // for, so no permission prompts fire.
        //
        // When `sandboxKey` is non-nil we use a STABLE per-key sandbox
        // instead of a fresh one. claude stores its session jsonl
        // inside a hash of the CWD — if every tick spawns in a
        // different sandbox, `--resume <uuid>` errors with "No
        // conversation with ID …" because the storage lives in the
        // previous (already-deleted) sandbox. Live AI passes the
        // session UUID as the key so all ticks share one sandbox; the
        // caller is responsible for cleaning it up via
        // `cleanupStableSandbox(key:)` when the session ends.
        let sandbox: URL
        let ephemeral: Bool
        if let key = sandboxKey {
            sandbox = stableSandboxDirectory(key: key)
            ephemeral = false
        } else {
            sandbox = makeSandboxDirectory()
            ephemeral = true
        }
        process.currentDirectoryURL = sandbox

        // Close stdin immediately. Some CLIs (claude) read both stdin AND
        // argv; some (cursor-agent) ignore stdin entirely. We standardised
        // on "transcript lives in argv" — see `composedPrompt` — so giving
        // the child an empty stdin is the consistent behaviour.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Only tear down the sandbox if it was ephemeral. Stable
        // session sandboxes are cleaned up by the caller when the
        // Live AI session ends.
        defer {
            if ephemeral {
                try? FileManager.default.removeItem(at: sandbox)
            }
        }

        do {
            try process.run()
        } catch {
            throw LLMRunnerError.launchFailed(error)
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Hand the live process to the handle so a Task cancel can terminate
        // it. If cancellation already fired before we got here, `attach`
        // sends SIGTERM right now; the wait-loop below picks up the exit
        // and we throw `.cancelled` instead of resuming with a partial
        // result the user no longer cares about.
        handle.attach(process)

        // Read stdout/stderr eagerly on background queues so a chatty CLI
        // can't deadlock by filling the OS pipe buffer while we waitUntilExit.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Bounded wait — kill the process if it's still running at deadline.
        let runningGroup = DispatchGroup()
        runningGroup.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            runningGroup.leave()
        }
        let deadline = DispatchTime.now() + .seconds(Int(timeout.rounded(.up)))
        let timedOut = runningGroup.wait(timeout: deadline) == .timedOut
        if timedOut {
            // SIGTERM first; if the CLI ignores it, hard-kill after a short
            // grace period so we don't read half-drained pipes or remove the
            // sandbox out from under a still-running child.
            process.terminate()
            if runningGroup.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                runningGroup.wait()
            }
        }
        // Drain the pipe readers once the process is known to be gone (either it
        // exited on its own or we killed it above).
        group.wait()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        return ProcessOutcome(stdout: stdout,
                              stderr: stderr,
                              // After a timeout the process was terminated, so
                              // its status is meaningless — report the standard
                              // SIGTERM-ish code so callers don't treat it as a
                              // clean exit.
                              exitCode: timedOut ? -1 : process.terminationStatus,
                              timedOut: timedOut,
                              cancelled: handle.wasTerminated)
    }

    /// Create a brand-new empty directory inside the system temp area. The
    /// child LLM process is chdir'd here so anything it scans for context
    /// finds nothing — no popups for Desktop, Downloads, Documents, etc.
    private static func makeSandboxDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-llm-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
                                                  withIntermediateDirectories: true)
        return url
    }

    /// Stable sandbox directory for a Claude session keyed by `key`
    /// (the session UUID). Reused across every tick of a Live AI
    /// session so claude's per-CWD session storage stays put and
    /// `--resume <uuid>` keeps finding the conversation.
    static func stableSandboxDirectory(key: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-llm-session-\(key)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
                                                  withIntermediateDirectories: true)
        return url
    }

    /// Tear down a stable session sandbox. Safe to call when the
    /// directory doesn't exist. Should be called by the Live AI
    /// session when it cancels so /tmp doesn't accumulate stale
    /// session dirs across recordings.
    static func cleanupStableSandbox(key: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-llm-session-\(key)",
                                    isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    private static func resolveExecutable(tool: LLMTool,
                                          override: String?) throws -> URL {
        // Absolute path override wins — handy for users with custom installs
        // or who want to point at a wrapper script (e.g. an asdf shim).
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw LLMRunnerError.executableNotFound(override)
            }
            return url
        }
        if let resolved = lookupOnPath(tool.executableName) {
            return resolved
        }
        throw LLMRunnerError.executableNotFound(tool.executableName)
    }

    /// Walk the user's `$PATH` plus a few common shell-managed locations
    /// (`~/.local/bin`, `/opt/homebrew/bin`, …). GUI apps on macOS inherit
    /// a stripped-down PATH from launchd, so claude/cursor installed by
    /// Homebrew or a node version manager are typically *not* on the
    /// inherited PATH — falling back to the well-known directories prevents
    /// the "works in Terminal, not in Mila" footgun.
    private static func lookupOnPath(_ name: String) -> URL? {
        var searchDirs: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            searchDirs += path.split(separator: ":").map(String.init)
        }
        let home = NSHomeDirectory()
        searchDirs += [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let fm = FileManager.default
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

/// Bridges Swift `Task` cancellation to the underlying `Process`.
///
/// The Task that called `LLMRunner.run` runs on a Swift concurrency thread;
/// the actual `Process` runs as an external child. There's no direct way to
/// propagate a Task cancel into the child, so this small handle is the
/// shared mutable state: the runner `attach`es the live Process; the
/// `onCancel` arm of `withTaskCancellationHandler` calls `terminate()`,
/// which SIGTERMs the child. `wasTerminated` lets the wait-loop tell the
/// difference between "exited on its own with a non-zero status" and "we
/// killed it because the user cancelled".
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var wasTerminated = false

    func attach(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        if wasTerminated {
            // Cancel beat us to attach — the Task was already cancelled
            // before the Process even started. Reach out and SIGTERM right
            // now so the child doesn't even get a head start.
            p.terminate()
            return
        }
        process = p
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        wasTerminated = true
        process?.terminate()
    }
}
