import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var hotkeySettings: HotkeySettings
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings

    @Binding var selection: SidebarSelection?
    let search: String

    /// Persisted across launches so the user's privacy choice (hide the
    /// Recent list while screen-sharing) sticks.
    @AppStorage("home.hideRecent") private var hideRecent: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                heroAction
                secondaryActions
                hotkeysCard
                recent
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    /// Wordmark + "by Island" tagline. The tagline is small and sits at
    /// the leading edge of the M so it reads as a credit line, not a
    /// second title.
    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("by Island")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.lowercase)
                Text("Mila")
                    .font(.system(size: 32, weight: .semibold))
            }
            Text("Record, dictate, and transcribe locally on your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    /// Hero action — the single tap that 90% of users come to Home for.
    /// Designed loud: large rounded rectangle, accent-coloured idle state,
    /// red pulsing "Recording…" state. Replaces the previous flat row of
    /// four identical gray tiles, which gave Voice Memo no visual edge
    /// over importing a file.
    private var heroAction: some View {
        HeroRecordButton(
            isRecording: isRecordingMic,
            languageFlag: languageSettings.current.flagEmoji,
            languageName: languageSettings.current.displayName
        ) {
            Task { await actions.toggleVoiceMemo() }
        }
        .frame(maxWidth: 460)
    }

    /// Three lower-priority entry points (file import, app audio capture,
    /// video → SRT) rendered as compact text-buttons rather than tiles —
    /// they're a one-tap means to an end, not a destination.
    private var secondaryActions: some View {
        HStack(spacing: 10) {
            SecondaryActionButton(icon: "folder", label: "Open Files") {
                Task { await actions.openFiles() }
            }
            SecondaryActionButton(icon: "speaker.wave.3.fill", label: "App Audio") {
                Task { await actions.presentAppPicker() }
            }
            SecondaryActionButton(icon: "captions.bubble", label: "Subtitle Video") {
                Task { await actions.subtitleVideo() }
            }
        }
        .frame(maxWidth: 460)
    }

    /// Always-visible card that documents the two dictation hotkeys so the
    /// user doesn't have to open Settings to remember which ⌘ combo does
    /// what. The bindings stay live — if a user rebinds in Settings the
    /// glyphs here update immediately.
    private var hotkeysCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "command.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Dictation hotkeys")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Press anywhere in macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                HotkeyChip(flag: "🇬🇧",
                           label: "English dictation",
                           binding: hotkeySettings.binding(for: .dictateEnglish).displayName)
                HotkeyChip(flag: "🇮🇱",
                           label: "Hebrew dictation",
                           binding: hotkeySettings.binding(for: .dictateHebrew).displayName)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    /// Whether the user is actively searching. When true we ignore the
    /// hideRecent toggle and show results anyway — otherwise typing into
    /// the search field with recents hidden was visibly a no-op and the
    /// user couldn't tell if their query matched anything.
    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isSearching ? "Search results" : "Recent")
                    .font(.title3.weight(.semibold))
                Spacer()
                if !isSearching {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            hideRecent.toggle()
                        }
                    } label: {
                        Label(hideRecent ? "Show" : "Hide",
                              systemImage: hideRecent ? "eye.slash" : "eye")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .help(hideRecent
                          ? "Show recent recordings"
                          : "Hide recent recordings (useful when sharing your screen)")
                }
            }

            // While searching, we always show results — even if recents are
            // hidden — because otherwise typing into the search box produces
            // no visible feedback. The hideRecent preference only governs
            // the idle (no-search) case.
            if hideRecent && !isSearching {
                hiddenPlaceholder
            } else {
                BucketedRecordingsView(
                    recordings: isSearching ? allRecordings : recentRecordings,
                    search: search,
                    selection: $selection
                )
            }
        }
    }

    /// Empty-state replacement when the user has hidden the Recent list.
    /// Keeps a visible affordance so it's obvious the list is hidden, not
    /// just empty.
    private var hiddenPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Recent recordings hidden")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var isRecordingMic: Bool {
        actions.activeJob == .recordingMic
    }

    private var recentRecordings: [Recording] {
        Array(store.recordings.filter { !$0.isTrashed }.prefix(30))
    }

    /// Full set used when searching — capped looser than the idle Recent
    /// list because the user explicitly asked for matches and might be
    /// hunting through old material.
    private var allRecordings: [Recording] {
        store.recordings.filter { !$0.isTrashed }
    }
}

/// Big primary "Record voice memo" CTA on Home. Replaces the old grid of
/// four equally-sized tiles where Voice Memo had no visual edge over
/// "Open Files". Idle state uses the system accent; the active state
/// flips to red with a pulsing ring so a glance across the room tells
/// you whether you're recording.
private struct HeroRecordButton: View {
    let isRecording: Bool
    let languageFlag: String
    let languageName: String
    let action: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 56, height: 56)
                    if isRecording {
                        Circle()
                            .stroke(Color.white.opacity(0.5), lineWidth: 2)
                            .frame(width: 56, height: 56)
                            .scaleEffect(pulse ? 1.6 : 1.0)
                            .opacity(pulse ? 0 : 0.9)
                    }
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isRecording ? "Recording…" : "Record")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Text(languageFlag)
                            .font(.callout)
                        Text(isRecording
                             ? "Tap to stop"
                             : "Voice memo · \(languageName)")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                    }
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
                    .strokeBorder(Color.white.opacity(hovering ? 0.25 : 0.12), lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: hovering ? 14 : 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.record.hero")
        .onHover { hovering = $0 }
        .onAppear { startPulseIfNeeded() }
        .onChange(of: isRecording) { _, _ in startPulseIfNeeded() }
    }

    /// Two-stop gradient: bright accent when idle, deep red when recording.
    /// The gradient sells the affordance better than a flat fill — buttons
    /// you "press to record" tend to look ceremonial in real apps.
    private var backgroundColors: [Color] {
        if isRecording {
            return [Color(red: 0.93, green: 0.27, blue: 0.27),
                    Color(red: 0.78, green: 0.18, blue: 0.18)]
        }
        return [Color.accentColor,
                Color.accentColor.opacity(0.78)]
    }

    private var shadowColor: Color {
        isRecording ? Color.red.opacity(0.35) : Color.accentColor.opacity(0.35)
    }

    private func startPulseIfNeeded() {
        guard isRecording else { pulse = false; return }
        pulse = false
        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}

/// Compact text-button entry for the three lower-priority actions. Lives
/// next to the hero record button so users can still get to imports / app
/// audio / video subtitles in one tap, but the visual weight matches
/// their priority — light, borderless, hover-feedback only.
private struct SecondaryActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tint)
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Visual chip used inside `hotkeysCard` to show one (flag, label, hotkey)
/// triple in a compact row.
private struct HotkeyChip: View {
    let flag: String
    let label: String
    let binding: String

    var body: some View {
        HStack(spacing: 10) {
            Text(flag)
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout.weight(.medium))
                Text(binding)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
