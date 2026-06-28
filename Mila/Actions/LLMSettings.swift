import Foundation
import Combine

/// Which local LLM CLI Mila will shell out to for naming
/// recordings and running post-recording actions. We deliberately keep this
/// to a closed set of two so the Settings UI can show working defaults +
/// concrete examples — supporting arbitrary CLIs would force the user to
/// know shell-quoting rules.
enum LLMTool: String, CaseIterable, Identifiable, Codable {
    case none
    case claude
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:   return "Off"
        case .claude: return "Claude (claude CLI)"
        case .cursor: return "Cursor (cursor-agent CLI)"
        }
    }

    /// Default executable name (looked up via the user's `$PATH`).
    var executableName: String {
        switch self {
        case .none:   return ""
        case .claude: return "claude"
        case .cursor: return "cursor-agent"
        }
    }

    /// Arguments for a one-shot, non-interactive print. Both `claude -p` and
    /// `cursor-agent -p` accept a prompt argument and stream the answer to
    /// stdout, exiting when done.
    ///
    /// `cursor-agent` also requires `-f` (force / trust the current working
    /// directory) in non-interactive mode — without it, the very first
    /// run bails with "Workspace Trust Required". We always pass it because
    /// the cwd is whatever launchd handed Mila, the user never
    /// sees it, and we're only asking the LLM to read a transcript.
    ///
    /// `model`, when non-empty, picks a specific model instead of the CLI's
    /// default — used by Live AI mode to pin a cheap model (Haiku) for
    /// the high-frequency action-item loop without changing the user's
    /// global CLI default.
    ///
    /// `session`, when non-`.none`, attaches the invocation to a named
    /// Claude conversation. Two modes:
    ///   * `.new(uuid)` → pass `--session-id <uuid>`; claude CREATES the
    ///     conversation. Reusing the same uuid later via `--session-id`
    ///     fails with "Session ID is already in use."
    ///   * `.resume(uuid)` → pass `--resume <uuid>`; claude continues
    ///     an existing conversation with all prior turns + responses in
    ///     scope.
    ///
    /// cursor-agent has no documented equivalent in `-p` mode and any
    /// session value is silently ignored for that tool.
    func arguments(prompt: String,
                   model: String? = nil,
                   session: LLMSession = .none) -> [String] {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasModel = !(trimmedModel?.isEmpty ?? true)
        switch self {
        case .none:   return []
        case .claude:
            var args: [String] = ["-p", prompt]
            if hasModel, let m = trimmedModel {
                args.append(contentsOf: ["--model", m])
            }
            switch session {
            case .none:
                break
            case .new(let id):
                args.append(contentsOf: ["--session-id", id.uuidString])
            case .resume(let id):
                args.append(contentsOf: ["--resume", id.uuidString])
            }
            return args
        case .cursor:
            var args: [String] = ["-p", "-f", prompt]
            if hasModel, let m = trimmedModel {
                args.append(contentsOf: ["--model", m])
            }
            // session intentionally ignored — see doc above.
            return args
        }
    }
}

/// Stateful-conversation mode for the LLM CLI. See
/// `LLMTool.arguments(prompt:model:session:)`.
enum LLMSession: Equatable {
    case none
    case new(UUID)
    case resume(UUID)
}

/// User-configurable prompts + tool selection for the LLM integration. The
/// "name" prompt is sent right after a recording transcribes so the user can
/// accept / reject a suggested title; the "action" prompt is what the user
/// pipes their transcript into for things like "summarize and email this".
@MainActor
final class LLMSettings: ObservableObject {
    @Published var tool: LLMTool {
        didSet {
            guard tool != oldValue else { return }
            defaults.set(tool.rawValue, forKey: Keys.tool)
        }
    }

    /// Optional override of the CLI executable path. When empty we rely on
    /// the system `$PATH` — convenient on dev machines, less so for users
    /// who installed claude/cursor in a non-shell-default location (e.g.
    /// `~/.local/bin`).
    @Published var executablePath: String {
        didSet {
            guard executablePath != oldValue else { return }
            defaults.set(executablePath, forKey: Keys.executablePath)
        }
    }

    @Published var nameGenerationEnabled: Bool {
        didSet { defaults.set(nameGenerationEnabled, forKey: Keys.nameEnabled) }
    }

    @Published var namePrompt: String {
        didSet { defaults.set(namePrompt, forKey: Keys.namePrompt) }
    }

    @Published var postActionEnabled: Bool {
        didSet { defaults.set(postActionEnabled, forKey: Keys.actionEnabled) }
    }

    @Published var postActionPrompt: String {
        didSet { defaults.set(postActionPrompt, forKey: Keys.actionPrompt) }
    }

    /// Maximum wall-clock seconds Mila allows a post-recording LLM call to
    /// run before killing the subprocess. Applies to title generation, the
    /// auto-summary, and the Send-action button. Live AI's per-tick timeouts
    /// are tuned separately and are not affected by this setting.
    @Published var cliTimeout: TimeInterval {
        didSet {
            guard cliTimeout != oldValue else { return }
            defaults.set(cliTimeout, forKey: Keys.cliTimeout)
        }
    }

    /// Master switch for the AUTOMATIC post-recording summary
    /// (`RecordingSummarizer`). When off, no summary is generated when a
    /// recording finishes, on launch backfill, or on re-transcription —
    /// the app behaves as a transcript-only tool. The explicit
    /// "Regenerate summary" affordance still works on demand; this only
    /// governs the automatic path.
    ///
    /// Defaults to ON (see init) so existing users keep their summaries
    /// unless they opt out. Surfaced in Settings → LLM next to the name /
    /// action toggles, which is where users expect to find it.
    @Published var summaryEnabled: Bool {
        didSet { defaults.set(summaryEnabled, forKey: Keys.summaryEnabled) }
    }

    /// Convenience the UI uses to decide whether to surface the rename /
    /// run-action buttons at all.
    var isConfigured: Bool { tool != .none }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawTool = defaults.string(forKey: Keys.tool) ?? LLMTool.none.rawValue
        self.tool = LLMTool(rawValue: rawTool) ?? .none
        self.executablePath = defaults.string(forKey: Keys.executablePath) ?? ""
        self.nameGenerationEnabled = defaults.bool(forKey: Keys.nameEnabled)
        self.namePrompt = defaults.string(forKey: Keys.namePrompt) ?? Self.defaultNamePrompt
        self.postActionEnabled = defaults.bool(forKey: Keys.actionEnabled)
        self.postActionPrompt = defaults.string(forKey: Keys.actionPrompt) ?? Self.defaultActionPrompt
        // Default-on: a bare `defaults.bool` would read false for users who
        // have never seen this key, silently disabling summaries for
        // everyone on upgrade. Treat "key absent" as true.
        self.summaryEnabled = (defaults.object(forKey: Keys.summaryEnabled) as? Bool) ?? true
        self.cliTimeout = (defaults.object(forKey: Keys.cliTimeout) as? Double) ?? 300
    }

    /// Default name prompt is deliberately *tool-free*. The previous default
    /// asked claude to read the Mac calendar, which made the CLI hang trying
    /// to use an MCP it didn't have — the symptom users hit was "Suggest
    /// never returns". Plain summarisation is the safe baseline; calendar
    /// lookup is offered as an example for users whose claude/cursor setup
    /// genuinely has that integration wired up.
    static let defaultNamePrompt =
        "Read the transcript below and reply with a 3–6 word title for it. Respond with just the title — no quotes, no punctuation, no preamble."
    static let defaultActionPrompt =
        "Summarize the transcript below as bullet points."

    /// Example pairs surfaced in the Settings UI as a "you could try…" hint.
    static let nameExamples: [String] = [
        "Read the transcript below and reply with a 3–6 word title — no quotes, no punctuation.",
        "If you have my Mac calendar configured, use the title of the current event; otherwise summarise the transcript in 3–6 words.",
        "Extract the most-mentioned topic from the transcript and use it as the title (3–6 words)."
    ]
    static let actionExamples: [String] = [
        "Summarize this and email the summary to the meeting attendees.",
        "Extract action items as a Markdown checklist and append to my daily note.",
        "Translate this transcript to English and copy to my clipboard."
    ]

    private enum Keys {
        static let tool = "llm.tool"
        static let executablePath = "llm.executablePath"
        static let nameEnabled = "llm.name.enabled"
        static let namePrompt = "llm.name.prompt"
        static let actionEnabled = "llm.action.enabled"
        static let actionPrompt = "llm.action.prompt"
        static let summaryEnabled = "llm.summary.enabled"
        static let cliTimeout = "llm.cli.timeout"
    }
}
