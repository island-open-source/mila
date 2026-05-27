import Foundation
import Combine

/// Persisted settings for the Live AI mode (split-pane recording with a
/// background LLM loop emitting action items). Off by default — even with
/// the toggle on, the feature only activates when the user has configured
/// the upstream LLM CLI in `LLMSettings` (so `isLiveAIReady` requires both).
///
/// Two cost dials live here so power users can shave dollars without
/// touching code: which model the CLI is asked to use (default = the
/// cheapest current Claude / Cursor model), and how often we tick the
/// LLM (default = every 5 s).
@MainActor
final class LiveAISettings: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }

    /// Model name passed to the CLI as `--model <value>`. Empty string ==
    /// "let the CLI pick" — typically the CLI's last-configured model. The
    /// UI nudges the user toward a cheap model via the placeholder.
    @Published var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }

    /// Tick frequency in seconds. The Live transcriber + LLM run on this
    /// cadence; lowering it costs more LLM calls (and more whisper CPU).
    @Published var chunkSeconds: Double {
        didSet { defaults.set(chunkSeconds, forKey: Keys.chunkSeconds) }
    }

    /// Speaker-similarity cosine threshold. ≥ this is the same speaker;
    /// below is a new speaker. 0.75 is a reasonable starting point for
    /// pyannote/embedding output.
    @Published var speakerSimilarityThreshold: Double {
        didSet { defaults.set(speakerSimilarityThreshold, forKey: Keys.simThreshold) }
    }

    /// System prompt sent to the CLI on every tick. Asks the model to emit
    /// a STRICT JSON object containing a rolling summary plus a list of
    /// action items so we can parse without a free-text regex. The
    /// prompt also defines wake-word semantics: anything the speaker
    /// says directly to "Mila" (or "מילה") becomes an item tagged
    /// `source: "voice_command"`.
    ///
    /// The literal token `{{LANGUAGE}}` in the prompt is replaced at
    /// send time with the user's chosen output language ("English" or
    /// "Hebrew"). Two reasons it lives in the prompt rather than as an
    /// instruction layered on top: (1) it makes the prompt itself
    /// editable in Settings without losing the language directive, and
    /// (2) keeping the substitution token visible reminds users not to
    /// strip it when customising.
    @Published var prompt: String {
        didSet { defaults.set(prompt, forKey: Keys.prompt) }
    }

    /// Output language for the LLM's summary and action items.
    /// Default English. The recording can still be in any language —
    /// this only controls what the AI's commentary comes back in.
    @Published var outputLanguage: OutputLanguage {
        didSet { defaults.set(outputLanguage.rawValue, forKey: Keys.outputLanguage) }
    }

    enum OutputLanguage: String, CaseIterable, Identifiable {
        case auto = "auto"
        case english = "en"
        case hebrew = "he"

        var id: String { rawValue }

        /// Name we substitute into the prompt's `{{LANGUAGE}}` slot. For
        /// `.auto` we tell the LLM to match whichever language the
        /// transcript itself is in — that's the right default since
        /// most users won't change the setting and a meeting in Hebrew
        /// shouldn't get English action items.
        var promptName: String {
            switch self {
            case .auto:    return "the same language as the transcript below"
            case .english: return "English"
            case .hebrew:  return "Hebrew"
            }
        }

        var displayName: String {
            switch self {
            case .auto:    return "Auto"
            case .english: return "English"
            case .hebrew:  return "Hebrew"
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Keys.enabled)
        self.model = defaults.string(forKey: Keys.model) ?? Self.defaultModel
        // Migrate pre-1.6.1 persisted values (default was 5s, range 3-20s).
        // 5s windows cut words mid-utterance and made the trailing-window
        // merge stitch together inconsistent segments. 30s = one full
        // window per tick, non-overlapping, clean boundaries.
        let raw = defaults.double(forKey: Keys.chunkSeconds)
        self.chunkSeconds = raw >= 25.0 ? raw : 30.0
        let sim = defaults.double(forKey: Keys.simThreshold)
        self.speakerSimilarityThreshold = sim > 0 ? sim : 0.75
        self.prompt = defaults.string(forKey: Keys.prompt) ?? Self.defaultPrompt
        let langRaw = defaults.string(forKey: Keys.outputLanguage) ?? OutputLanguage.auto.rawValue
        self.outputLanguage = OutputLanguage(rawValue: langRaw) ?? .auto
    }

    /// Default "cheap" model. Currently `claude-haiku-4-5` — the smallest
    /// member of the 4.5 generation. Users on cursor-agent can override
    /// in Settings if their CLI accepts a different model name.
    static let defaultModel = "claude-haiku-4-5"

    /// The default prompt. Idempotent: we re-send the full growing
    /// transcript on every tick and the model re-emits the FULL list
    /// (plus the latest rolling summary) every time, so the UI always
    /// gets a complete snapshot. Dedup happens in Swift via the `id`
    /// field on each item.
    ///
    /// `{{LANGUAGE}}` is substituted with the user's chosen output
    /// language at send time. If a user removes it from a custom prompt
    /// the LLM falls back to whatever language the transcript itself
    /// is in — fine for matching the conversation, but the user picked
    /// a setting for a reason, so we keep the substitution token in
    /// the default text.
    static let defaultPrompt = """
You are Mila, a live meeting assistant. Output everything in {{LANGUAGE}}.

You are called repeatedly as a live meeting unfolds. Each call gives
you additional transcript. Your response REPLACES the entire panel
the user sees, so you MUST output the COMPLETE current state on
every single call:
  • The FULL list of action items — every one you have ever
    identified, not just the new ones.
  • The FULL rolling summary — refresh and rewrite it to cover the
    whole conversation so far, not just the latest chunk.

Treat every response as if the previous response no longer exists.
Do not assume the user retains anything from earlier calls. Repeat
every action item, with its stable id, in every reply. If you
realise an earlier item was wrong, simply omit it (the user's panel
will reflect that). If you want to update an item, re-emit it with
the SAME id and new text. If the speaker repeats themselves, the
item still appears exactly ONCE.

An action item is:
- A concrete task someone committed to do (with or without a deadline).
- An explicit instruction directed at you (e.g. "Mila, add ..." or in Hebrew "מילה, הוסף..."). Tag those with source: "voice_command".

OUTPUT FORMAT: respond with ONLY a JSON object on a single line — no \
preamble, no Markdown, no trailing text:
{"summary": "...", "items": [{"id": "stable-slug", "text": "...", "speaker": "SPEAKER_00" or null, "timestamp_seconds": 0, "source": "inferred" or "voice_command"}]}

If the call has just started and there is no transcript yet, output \
{"summary": "", "items": []}.
"""

    private enum Keys {
        static let enabled = "liveAI.enabled"
        static let model = "liveAI.model"
        static let chunkSeconds = "liveAI.chunkSeconds"
        static let simThreshold = "liveAI.speakerSimilarityThreshold"
        static let prompt = "liveAI.prompt"
        static let outputLanguage = "liveAI.outputLanguage"
    }
}

/// One action item surfaced by `LiveAISession`. The `id` is chosen by the
/// LLM and is stable across ticks so we can dedupe; `addedAt` is when the
/// item first appeared in our UI (so the list can be sorted newest-first
/// without trusting the LLM's `timestamp_seconds`).
struct ActionItem: Identifiable, Hashable, Codable {
    let id: String
    var text: String
    var speaker: String?
    var timestampSeconds: Double
    var source: Source
    var addedAt: Date

    enum Source: String, Codable {
        case llmInferred = "inferred"
        case voiceCommand = "voice_command"
    }
}
