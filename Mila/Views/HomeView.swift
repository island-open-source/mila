import SwiftUI

/// Home is intentionally bare: the wordmark, a one-line tagline, and a
/// single big Record button with an "also record app audio" toggle
/// underneath. Everything else (file import, app audio picker, video
/// subtitling) moved to the sidebar's More page; the Recent list and
/// the dictation-hotkeys card both moved off Home — hotkeys live in
/// the toolbar now, recordings live in the All Transcriptions folder.
struct HomeView: View {
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings
    @EnvironmentObject private var hotkeys: HotkeySettings
    @EnvironmentObject private var liveAISettings: LiveAISettings
    @EnvironmentObject private var llmSettings: LLMSettings
    /// Observed so the Record button can show a one-time-setup
    /// spinner while CoreML compiles the encoder mlmodelc (~13s on
    /// M-series the very first time). See
    /// `TranscriptionService.isPreparingModel`.
    @EnvironmentObject private var transcription: TranscriptionService

    @Binding var selection: SidebarSelection?
    let search: String

    /// User's preference for capturing the system's audio mix. Defaults
    /// to ON because the main use case is meeting / content
    /// transcription. Paired with `recordMicrophone` below — the two
    /// toggles select the source (mic+app = meeting, mic-only =
    /// microphone, app-only = system audio). The choice sticks across
    /// launches.
    @AppStorage("home.record.withSystemAudio") private var withSystemAudio: Bool = true

    /// User's preference for capturing the microphone. Defaults to ON
    /// (the historical behaviour — Record always included the mic).
    /// Turning this OFF while App audio is ON records system audio only
    /// (no mic), which is what you want to capture an app/meeting you're
    /// only listening to.
    @AppStorage("home.record.microphone") private var recordMicrophone: Bool = true

    /// At least one source must be on to record.
    private var canRecord: Bool { recordMicrophone || withSystemAudio }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 24) {
                header
                heroAction
                sourceToggles
                dictationHint
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Wordmark: "Mila" + a small "by Island" credit to the right at the
    /// .lastTextBaseline so the small caps sit flush with the bottom of
    /// the big wordmark. One-liner tagline below.
    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("Mila")
                    .font(.system(size: 36, weight: .semibold))
                HStack(alignment: .center, spacing: 4) {
                    Text("by Island")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    // Island brand mark. The asset is already grayscale
                    // (two-tone — see IslandLogo.svg) so the horizon
                    // line stays visible at 14×14. No `.saturation(0)`
                    // — the previous color-and-desaturate combo
                    // collapsed both gradients to the same mid-gray
                    // and the circle looked like a flat disk.
                    Image("IslandLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
            }
            Text("Record, dictate, and transcribe locally on your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// The single primary CTA. Hands off to QuickActionsController
    /// which chooses mic-only vs mic+system based on the checkbox.
    private var heroAction: some View {
        HeroRecordButton(
            isRecording: isRecording,
            isFinalizing: actions.isFinalizingRecording,
            isPreparingModel: transcription.isPreparingModel,
            preparationStatus: transcription.preparationStatus,
            languageFlag: languageSettings.current.flagEmoji,
            languageName: languageSettings.current.displayName,
            microphoneEnabled: recordMicrophone,
            withSystemAudio: withSystemAudio,
            liveAIEnabled: liveAISettings.enabled && llmSettings.isConfigured
        ) {
            Task { await actions.toggleRecord(microphone: recordMicrophone, appAudio: withSystemAudio) }
        }
        .frame(maxWidth: 460)
        // Belt-and-suspenders with the controller-side guard: greying
        // out the button gives the user immediate visual feedback that
        // a tap during the drain won't do anything, instead of just
        // silently swallowing it.
        //
        // Same idea for the first-time CoreML compile: a record press
        // during the compile window would start a recording the encoder
        // can't yet transcribe (segments=0). Block the button until the
        // engine reports ready.
        .disabled(actions.isFinalizingRecording || transcription.isPreparingModel || !canRecord)
    }

    /// The two independent source toggles below the Record button:
    /// Microphone and App audio. Both default-on (= meeting capture).
    /// Turn the mic off to record app audio only; turn app audio off for
    /// a plain voice memo. Disabled while a recording is in flight so the
    /// user can't change the source mid-capture. When both are off, a
    /// hint replaces the (disabled) Record affordance's silence.
    private var sourceToggles: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $recordMicrophone) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.callout)
                        .foregroundStyle(.tint)
                    Text("Microphone")
                        .font(.callout)
                }
            }
            .help("Capture your microphone. Turn off to record app audio only (e.g. a meeting or video you're just listening to).")
            .accessibilityIdentifier("home.record.microphone.toggle")

            Toggle(isOn: $withSystemAudio) {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.callout)
                        .foregroundStyle(.tint)
                    Text("App audio")
                        .font(.callout)
                }
            }
            .help("Capture audio from any app playing on this Mac. Required for meeting / video transcription.")
            .accessibilityIdentifier("home.record.appaudio.toggle")

            if !canRecord {
                Text("Turn on at least one source to record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isRecording)
        .frame(maxWidth: 280, alignment: .leading)
    }

    /// Discrete reminder of the two global dictation hotkeys. Reads live
    /// from HotkeySettings so a rebind in Settings is reflected here
    /// without a restart. Visually low-key — secondary color, small
    /// caption font, no background pill / button affordance — because
    /// this is a hint about something the user does OUTSIDE the app via
    /// the system-wide hotkey, not a button to click.
    private var dictationHint: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Text("🇬🇧")
                Text("dictate")
                Text(hotkeys.binding(for: .dictateEnglish).displayName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.7))
            }
            Text("·")
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                Text("🇮🇱")
                Text("dictate")
                Text(hotkeys.binding(for: .dictateHebrew).displayName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.7))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Press these shortcuts anywhere in macOS to dictate. Configure in Settings → Hotkeys.")
        .accessibilityIdentifier("home.dictation.hint")
    }

    private var isRecording: Bool {
        actions.isRecording
    }
}

/// Big primary "Record" CTA. Idle state is a quiet gray surface so the
/// page isn't shouting at the user when nothing's happening. The
/// recording state flips to the system accent (blue) with a pulsing
/// ring and a literal red square stop indicator inside the icon
/// circle — once you're recording you want it loud and unmissable.
private struct HeroRecordButton: View {
    let isRecording: Bool
    /// True while `stopRecording`'s inline drain is running. The button
    /// is `.disabled` in this state (set by the caller) but we also want
    /// the visible title/caption to say "Finalizing…" so the user
    /// understands why pressing it again doesn't do anything.
    let isFinalizing: Bool
    /// True while the whisper engine is doing a noticeable first-time
    /// load — currently only the first CoreML compile of a sibling
    /// `-encoder.mlmodelc`. The button is disabled by the caller in
    /// this state and we relabel it ("Preparing Neural Engine…") plus
    /// show a spinner so the user knows the wait is one-time and
    /// progress is being made.
    let isPreparingModel: Bool
    /// Optional human-readable line the engine asked us to show
    /// alongside the spinner (e.g. "Preparing Neural Engine
    /// (one-time setup)…"). Falls back to a sensible default when nil.
    let preparationStatus: String?
    let languageFlag: String
    let languageName: String
    let microphoneEnabled: Bool
    let withSystemAudio: Bool
    /// True when Live AI mode is on AND a CLI is configured. Drives the
    /// title ("Transcribe and Summarize" vs "Transcribe") and the small
    /// sparkle on the mic icon — so the user can tell at a glance
    /// whether pressing record will also fire the LLM loop.
    let liveAIEnabled: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(iconCircleFill)
                        .frame(width: 56, height: 56)
                    if isPreparingModel {
                        // First-time CoreML compile in flight. Show an
                        // indeterminate spinner inside the icon circle
                        // — same footprint as the mic glyph so the
                        // layout doesn't jump when state flips.
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .accessibilityIdentifier("home.record.preparing.spinner")
                    } else if isRecording {
                        Circle()
                            .stroke(Color.white.opacity(0.5), lineWidth: 2)
                            .frame(width: 56, height: 56)
                            .scaleEffect(pulse ? 1.6 : 1.0)
                            .opacity(pulse ? 0 : 0.9)
                        // Explicit red square as the stop indicator. The
                        // SF Symbol `stop.fill` was an option but a
                        // literal red square reads more like "press to
                        // stop this recording" at a glance.
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.red)
                            .frame(width: 24, height: 24)
                    } else {
                        // App-only capture (mic off) shows a speaker glyph
                        // so the idle button reflects what it'll record.
                        Image(systemName: microphoneEnabled ? "mic.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.85))
                        if liveAIEnabled {
                            // Small sparkle nudged into the upper-right
                            // corner of the icon circle to signal that
                            // pressing record will also run the LLM
                            // loop. The badge background matches the
                            // app accent so it reads as "AI" without
                            // needing a tooltip.
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Color.accentColor, in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                                .offset(x: 18, y: -18)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(textColor)
                    Text(captionText)
                        .font(.callout)
                        .foregroundStyle(captionColor)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: backgroundColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: hovering ? 14 : 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.record.hero")
        .onHover { hovering = $0 }
        .onAppear { startPulseIfNeeded() }
        .onChange(of: isRecording) { _, _ in startPulseIfNeeded() }
    }

    /// Inner icon circle fill — slightly transparent white on the blue
    /// recording state (so it reads as a translucent bezel around the
    /// stop square), darker neutral on the gray idle state so the mic
    /// glyph still has contrast against it.
    private var iconCircleFill: Color {
        isRecording ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)
    }

    private var textColor: Color {
        isRecording ? .white : .primary
    }

    private var captionColor: Color {
        isRecording ? Color.white.opacity(0.9) : .secondary
    }

    private var strokeColor: Color {
        if isRecording {
            return Color.white.opacity(hovering ? 0.25 : 0.12)
        }
        return Color.primary.opacity(hovering ? 0.18 : 0.10)
    }

    private var titleText: String {
        if isPreparingModel { return "Preparing AI…" }
        if isFinalizing { return "Finalizing…" }
        if isRecording { return "Recording…" }
        return liveAIEnabled ? "Transcribe and Summarize" : "Transcribe"
    }

    private var captionText: String {
        if isPreparingModel {
            // Engine-provided status takes precedence so the copy can
            // evolve without a UI change. The fallback covers the
            // "engine said preparing but didn't supply a string" case.
            return preparationStatus ?? "One-time setup (about 15 seconds)…"
        }
        if isFinalizing {
            return "Saving transcript…"
        }
        if isRecording {
            return "Tap to stop"
        }
        let sourceLabel: String
        switch (microphoneEnabled, withSystemAudio) {
        case (true, true):   sourceLabel = "Mic + app audio"
        case (true, false):  sourceLabel = "Microphone"
        case (false, true):  sourceLabel = "App audio only"
        case (false, false): sourceLabel = "No source selected"
        }
        return "\(languageFlag) \(languageName) · \(sourceLabel)"
    }

    private var backgroundColors: [Color] {
        if isRecording {
            // Loud accent-blue gradient while recording — same look the
            // old "idle" state used to have. It's visible from across
            // the room so you never forget the mic is hot.
            return [Color.accentColor,
                    Color.accentColor.opacity(0.78)]
        }
        // Quiet gray gradient when idle. NSColor.controlColor adapts
        // to light / dark mode automatically, and the slight gradient
        // gives the button a little depth without screaming "primary
        // CTA" — Record is the only button on Home, the visual weight
        // doesn't need to fight for attention.
        let base = Color(NSColor.controlColor)
        return [base.opacity(0.95), base.opacity(0.7)]
    }

    private var shadowColor: Color {
        isRecording ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.10)
    }

    private func startPulseIfNeeded() {
        guard isRecording else { pulse = false; return }
        pulse = false
        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
