import Foundation

/// Errors surfaced from the CLI invocation. The Settings UI / rename sheet
/// renders `errorDescription` directly so users can self-diagnose path /
/// permission issues without reading logs.
enum LLMRunnerError: LocalizedError {
    case toolDisabled
    case executableNotFound(String)
    case launchFailed(Error)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut
    case emptyOutput

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
        case .timedOut:
            return "LLM CLI did not respond within the timeout."
        case .emptyOutput:
            return "LLM CLI returned no output. Check the prompt or your CLI's auth."
        }
    }
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

    /// Format the transcript into a prompt the CLI will see. Kept as a
    /// distinct function so tests can assert on the exact wire format.
    static func composedPrompt(_ userPrompt: String, transcript: String) -> String {
        let prompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return prompt }
        return "\(prompt)\n\n---\nTranscript:\n\(body)"
    }

    /// Run `tool` with `prompt` + `transcript`. Returns stdout, trimmed.
    /// Throws `LLMRunnerError` on any failure.
    ///
    /// `executablePathOverride` lets the user point at a binary in a
    /// non-PATH location (e.g. `/Users/foo/.local/bin/claude`).
    ///
    /// `timeout` defaults to 5 minutes. Pass a smaller value for foreground
    /// callers that block UI (e.g. the Suggest button).
    static func run(tool: LLMTool,
                    prompt: String,
                    transcript: String,
                    executablePathOverride: String?,
                    timeout: TimeInterval = LLMRunner.defaultTimeout) async throws -> String {
        guard tool != .none else { throw LLMRunnerError.toolDisabled }

        let executable = try resolveExecutable(tool: tool,
                                               override: executablePathOverride)
        let fullPrompt = composedPrompt(prompt, transcript: transcript)
        print("LLMRunner: \(executable.lastPathComponent) prompt=\(fullPrompt.count)c timeout=\(Int(timeout))s")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runProcess(executable: executable,
                                                arguments: tool.arguments(prompt: fullPrompt),
                                                timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runProcess(executable: URL,
                                   arguments: [String],
                                   timeout: TimeInterval) throws -> String {
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
        // sees scary TCC prompts saying "IslandWhisper would like to access
        // Desktop / Downloads". Launching from an isolated, empty directory
        // guarantees there's nothing for the LLM CLI to discover and reach
        // for, so no permission prompts fire.
        let sandbox = makeSandboxDirectory()
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

        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            try process.run()
        } catch {
            throw LLMRunnerError.launchFailed(error)
        }
        try? stdinPipe.fileHandleForWriting.close()

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
        if runningGroup.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
            throw LLMRunnerError.timedOut
        }
        group.wait()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw LLMRunnerError.nonZeroExit(code: process.terminationStatus,
                                             stderr: stderr.isEmpty ? stdout : stderr)
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create a brand-new empty directory inside the system temp area. The
    /// child LLM process is chdir'd here so anything it scans for context
    /// finds nothing — no popups for Desktop, Downloads, Documents, etc.
    private static func makeSandboxDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-whisper-llm-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
                                                  withIntermediateDirectories: true)
        return url
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
    /// the "works in Terminal, not in Island Whisper" footgun.
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
