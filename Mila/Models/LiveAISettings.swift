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

    /// Snapshot of the host Mac's hardware identity. Injected in tests
    /// (so `isLiveAIAvailable` can be exercised without a real
    /// MacBook Air); defaults to `SystemCapabilities.live` in
    /// production. The choice is made at init time and never
    /// reassigned — hardware doesn't change at runtime.
    let capabilities: SystemCapabilities

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

    /// When true, the live transcriber routes audio through a VAD
    /// instead of cutting on a fixed time interval. Whisper runs once
    /// per detected utterance (on silence ≥400ms), capped at 25s for
    /// monologues. Off by default for now — opt-in beta until we've
    /// tuned the RMS threshold against real recordings.
    @Published var useVAD: Bool {
        didSet { defaults.set(useVAD, forKey: Keys.useVAD) }
    }

    /// When true, the recording UI stays on the Home screen (just a
    /// Stop button) instead of switching to the LiveAIRecordingView's
    /// split pane. Transcription + summary continue to run in the
    /// background and are saved when the recording stops. Useful for
    /// lower-power Macs (MacBook Air etc.) where the live pane's
    /// continuous rendering competes with whisper for CPU.
    @Published var backgroundMode: Bool {
        didSet { defaults.set(backgroundMode, forKey: Keys.backgroundMode) }
    }

    /// Override that lets a user opt into Live AI on hardware the
    /// auto-detect rules excluded (MacBook Air etc.). Off by default —
    /// the auto-detect is right for most users. Surfaced as an
    /// "Override hardware gate" toggle inside the "Disabled on this
    /// Mac" notice block in Settings so it's only visible when
    /// relevant. With ANE encoder offload landed, the actual realtime
    /// budget on Airs is much closer to fast Macs than when the gate
    /// was first added; this toggle lets us collect signal without
    /// flipping the default for everyone.
    @Published var forceLiveAIOnLowEndHardware: Bool {
        didSet { defaults.set(forceLiveAIOnLowEndHardware, forKey: Keys.forceLowEnd) }
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

    /// Whether Live AI's live-transcript / action-items pane should be
    /// offered on this hardware. False on MacBook Air (whisper +
    /// pyannote together are too slow on Air-class chips to feel
    /// real-time); true on every other Mac. Independent of the user's
    /// `enabled` toggle and of whether the LLM CLI is configured —
    /// this is purely "is the feature reachable on this machine."
    ///
    /// The user's `enabled` preference is still persisted across
    /// launches (it round-trips even when unavailable), so taking the
    /// app from a slow Mac back to a fast Mac restores the previous
    /// state without surprises.
    var isLiveAIAvailable: Bool {
        capabilities.isLiveAIRecommended || forceLiveAIOnLowEndHardware
    }

    /// Whether Live AI is currently ready to actually run — i.e. the
    /// hardware supports it AND the user has an LLM CLI configured.
    /// The user's `enabled` toggle is intentionally NOT part of this
    /// gate: callers compose `isLiveAIReady && enabled` themselves so
    /// the readiness signal can also be used to grey out the toggle
    /// in Settings without flipping the persisted preference.
    func isLiveAIReady(llmConfigured: Bool) -> Bool {
        llmConfigured && isLiveAIAvailable
    }

    /// Prompt used for the post-recording one-shot summary. This fires
    /// after a recording finishes whenever the LLM CLI is configured —
    /// not just when Live AI mode was on during the recording — so every
    /// recording ends up with a summary even if the user never opted
    /// into the live split-pane UI. Kept separate from `prompt` (the
    /// Live AI tick prompt) because the live prompt asks for a JSON
    /// envelope with action items, which is overkill for a one-shot
    /// plain-text summary. `{{LANGUAGE}}` is substituted at send time
    /// the same way `prompt` does.
    @Published var summaryPrompt: String {
        didSet { defaults.set(summaryPrompt, forKey: Keys.summaryPrompt) }
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

    init(defaults: UserDefaults = .standard,
         capabilities: SystemCapabilities = .live) {
        self.defaults = defaults
        self.capabilities = capabilities
        // Default ON: users who never touched the toggle should get
        // the LLM summary/action-items pane. If their LLM CLI isn't
        // configured, `isLiveAIReady` still gates everything down to
        // a no-op, so this is safe.
        self.enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        self.model = defaults.string(forKey: Keys.model) ?? Self.defaultModel
        // Migrate pre-1.6.1 persisted values (default was 5s, range 3-20s).
        // 5s windows cut words mid-utterance and made the trailing-window
        // merge stitch together inconsistent segments. 30s = one full
        // window per tick, non-overlapping, clean boundaries.
        let raw = defaults.double(forKey: Keys.chunkSeconds)
        self.chunkSeconds = raw >= 25.0 ? raw : 30.0
        // Default ON: users who never touched the toggle get the
        // cleaner-boundary VAD path. Explicit false is preserved.
        self.useVAD = defaults.object(forKey: Keys.useVAD) as? Bool ?? true
        self.backgroundMode = defaults.bool(forKey: Keys.backgroundMode)
        self.forceLiveAIOnLowEndHardware = defaults.bool(forKey: Keys.forceLowEnd)
        let sim = defaults.double(forKey: Keys.simThreshold)
        // Migrate the old 0.75 default — too strict for wespeaker on
        // 1-5s VAD utterances; same-speaker cosine sim at that length
        // sits in 0.5-0.7, so 0.75 split every utterance into a new
        // SPEAKER_NN. Treat values >= 0.7 as "old default, migrate".
        self.speakerSimilarityThreshold = (sim > 0 && sim < 0.7) ? sim : 0.55
        self.prompt = defaults.string(forKey: Keys.prompt) ?? Self.defaultPrompt
        let langRaw = defaults.string(forKey: Keys.outputLanguage) ?? OutputLanguage.auto.rawValue
        self.outputLanguage = OutputLanguage(rawValue: langRaw) ?? .auto
        self.summaryPrompt = defaults.string(forKey: Keys.summaryPrompt) ?? Self.defaultSummaryPrompt
    }

    /// Default model. Currently `claude-sonnet-4-6` — better
    /// summarisation quality than Haiku at modest extra cost. Users
    /// on cursor-agent can override in Settings if their CLI accepts
    /// a different model name.
    static let defaultModel = "claude-sonnet-4-6"

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

    /// Default one-shot summary prompt. Plain-text, meeting-style — no
    /// JSON envelope, no action items, no "you've been called repeatedly"
    /// framing. This runs ONCE against the full transcript after a
    /// recording finishes, so the prompt can assume the model has the
    /// complete picture and just needs to produce a concise human-readable
    /// summary. `{{LANGUAGE}}` is substituted at send time.
    static let defaultSummaryPrompt = """
You are summarizing a meeting transcript. Output everything in {{LANGUAGE}}.

Read the transcript below and produce a concise summary suitable for
someone who didn't attend the meeting. Cover:
  • What was discussed (the main topics).
  • Any decisions that were made.
  • Any action items or follow-ups that came up.

Keep it short — a few bullet points or a short paragraph is fine. Do
NOT include a preamble like "Here is the summary"; start directly with
the content.
"""

    private enum Keys {
        static let enabled = "liveAI.enabled"
        static let model = "liveAI.model"
        static let chunkSeconds = "liveAI.chunkSeconds"
        static let useVAD = "liveAI.useVAD"
        static let backgroundMode = "liveAI.backgroundMode"
        static let forceLowEnd = "liveAI.forceOnLowEndHardware"
        static let simThreshold = "liveAI.speakerSimilarityThreshold"
        static let prompt = "liveAI.prompt"
        static let outputLanguage = "liveAI.outputLanguage"
        static let summaryPrompt = "liveAI.summaryPrompt"
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
