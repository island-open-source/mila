import SwiftUI
import OSLog

/// Replaces the Home view while a recording is active AND Live AI mode is
/// configured + enabled. Two stacked panes (top: action items, bottom:
/// live transcript) with the recording controls in the header strip.
///
/// The pane heights default to a balanced 50/50 — we use a `VSplitView`
/// rather than fixed fractions so users with very different action-item
/// vs. transcript volumes can drag the divider to fit their preference.
struct LiveAIRecordingView: View {
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var transcriber: LiveTranscriber
    @EnvironmentObject private var diarizer: LiveSpeakerDiarizer
    @EnvironmentObject private var aiSession: LiveAISession
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings
    @EnvironmentObject private var liveAISettings: LiveAISettings
    @EnvironmentObject private var llmSettings: LLMSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            // Action items pane is rendered only when Live AI is on +
            // a CLI is configured. When AI is off the live transcript
            // takes the whole detail pane so the user still sees what
            // Mila is hearing in real time.
            if aiActive {
                VSplitView {
                    actionItemsPane
                        .frame(minHeight: 140)
                    liveTranscriptPane
                        .frame(minHeight: 140)
                }
            } else {
                liveTranscriptPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Recording's current language. Drives RTL handling for the
    /// transcript pane + friendly speaker labels.
    private var language: String { languageSettings.current.rawValue }
    private var isRTL: Bool { language == "he" }
    private var aiActive: Bool { liveAISettings.enabled && llmSettings.isConfigured }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await actions.stopRecording() }
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text("Stop")
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)

            VStack(alignment: .leading, spacing: 2) {
                Text(aiActive ? "Recording — Live AI" : "Recording")
                    .font(.callout.weight(.semibold))
                Text(elapsedString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text("\(languageSettings.current.flagEmoji) \(languageSettings.current.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if aiActive {
                ThinkingIndicator(isThinking: aiSession.isThinking)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var elapsedString: String {
        // Read directly from session — its `@Published var elapsed`
        // ticks every 200 ms. Reading via actions.elapsed (a computed
        // pass-through) didn't subscribe to session's publisher, so
        // the body only re-rendered when something else in `actions`
        // changed (typically not until a 5 s LLM tick or a mic-level
        // bump), making the timer look like it was updating every
        // few seconds.
        let t = Int(session.elapsed.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: - Action items pane

    @ViewBuilder
    private var actionItemsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Summary & action items")
                    .font(.callout.weight(.semibold))
                Spacer()
                if let err = aiSession.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Two bulleted sections, summary on top, action items
            // below. Both are live — the LLM re-emits a refreshed
            // summary on every tick (per the updated default prompt)
            // so the bullets here update as the conversation evolves.
            // The action-items section is hidden when empty so a
            // conversation that hasn't produced concrete tasks yet
            // doesn't show an empty "Action items" header.
            if aiSession.summary.isEmpty && aiSession.actionItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !aiSession.summary.isEmpty {
                            summarySection
                        }
                        if !aiSession.actionItems.isEmpty {
                            actionItemsSection
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Render the LLM's rolling summary as a bulleted list. The LLM
    /// usually returns one paragraph (1-3 sentences); we split on
    /// sentence boundaries so each sentence becomes its own bullet
    /// — that's the "summary as bullet points" look the user asked
    /// for, without forcing a prompt change that would risk
    /// breaking JSON parsing.
    private var summarySection: some View {
        let bullets = Self.bulletsFromSummary(aiSession.summary)
        let isRTL = aiSession.summary.isPredominantlyHebrew || language == "he"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "text.alignleft").foregroundStyle(.tint)
                Text("Summary").font(.callout.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(bullets, id: \.self) { line in
                    BulletLine(text: line)
                }
            }
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
        }
    }

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "checklist").foregroundStyle(.tint)
                Text("Action items").font(.callout.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(aiSession.actionItems) { item in
                    ActionItemRow(item: item, language: language)
                }
            }
        }
    }

    /// Split a rolling summary paragraph into one bullet per sentence.
    /// Falls back to the whole string as a single bullet when no
    /// sentence boundary is found — better than showing nothing.
    static func bulletsFromSummary(_ s: String) -> [String] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Split on '. ', '! ', '? ' and the Hebrew full stop "׃ " plus
        // line breaks. Filter empties.
        let parts = trimmed
            .split(whereSeparator: { ".!?\n".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [trimmed] : parts
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ear")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("Listening…")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Action items appear here when something concrete comes up. Say **\"Mila, …\"** to add one yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
    }

    // MARK: - Live transcript pane

    private var liveTranscriptPane: some View {
        // Detect Hebrew from the accumulated transcript text — much
        // more reliable than the language dropdown, which the user
        // may not have flipped before pressing Record.
        let paneIsRTL = transcriber.fullText.isEmpty
            ? (language == "he")
            : transcriber.fullText.isPredominantlyHebrew
        // For Hebrew we use explicit `.trailing` frame alignment +
        // `.trailing` text alignment instead of flipping
        // `\.layoutDirection`. Setting layoutDirection here
        // mis-measured the inner ScrollView frame when the sidebar
        // was open — visibly shifted the Hebrew block left away
        // from the right edge by the sidebar's width. With explicit
        // alignment, each Text just stays pinned to whichever edge
        // we name, regardless of how the parent is sized.
        let textAlignment: Alignment = paneIsRTL ? .trailing : .leading
        let multilineAlignment: TextAlignment = paneIsRTL ? .trailing : .leading
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "text.quote")
                    .foregroundStyle(.secondary)
                Text("Live transcript")
                    .font(.callout.weight(.semibold))
                Spacer()
                if transcriber.isTranscribing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        let _ = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "LiveAIRecordingView")
                            .log("render segments.count=\(transcriber.segments.count, privacy: .public)")
                        if transcriber.segments.isEmpty {
                            Text("Listening…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: textAlignment)
                                .accessibilityIdentifier("liveTranscript.listening")
                        } else {
                            ForEach(transcriber.segments) { seg in
                                Text(seg.text)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(multilineAlignment)
                                    .frame(maxWidth: .infinity, alignment: textAlignment)
                                    .accessibilityIdentifier("liveTranscript.segment")
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("transcript-body")
                    .accessibilityIdentifier("liveTranscript.container")
                    Color.clear.frame(height: 1).id("bottom-anchor")
                }
                .onChange(of: transcriber.segments.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.02))
    }
}

/// Single line with a leading bullet. RTL-aware so Hebrew text flows
/// right-to-left with the bullet on the right.
private struct BulletLine: View {
    let text: String

    private var isRTL: Bool { text.isPredominantlyHebrew }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let language: String

    /// Per-row RTL detection so a Hebrew action item flips alignment
    /// even on a recording whose language dropdown was left on
    /// English.
    private var isRTL: Bool {
        if language == "he" { return true }
        return item.text.isPredominantlyHebrew
    }

    var body: some View {
        // IMPORTANT: when `\.layoutDirection` is `.rightToLeft`, the
        // semantic alignments .leading / .trailing already MIRROR —
        // `.leading` becomes the right edge, `.trailing` becomes the
        // left. Using `.trailing` while ALSO setting the env value
        // double-flipped and put Hebrew text on the LEFT. The fix is
        // to use `.leading` everywhere and let layoutDirection do the
        // mirroring exactly once.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if hasMetadata {
                    HStack(spacing: 8) {
                        if let speaker = item.speaker {
                            Text(speaker.friendlySpeakerLabel(language: language))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if item.timestampSeconds > 0 {
                            Text(formatTimestamp(item.timestampSeconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if item.source == .voiceCommand {
                            Text("(voice command)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
        .padding(.vertical, 2)
    }

    private var hasMetadata: Bool {
        item.speaker != nil || item.timestampSeconds > 0 || item.source == .voiceCommand
    }

    private func formatTimestamp(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct TranscriptLineView: View {
    let segment: LiveSegment
    let language: String

    var body: some View {
        // We rely on the PARENT pane's layoutDirection. That mirrors the
        // HStack (speaker badge ends up on the right in RTL, text fills
        // the remaining space leftward) without us having to flip
        // alignment per child. Per-line we still override layoutDirection
        // when the line's text is the opposite of the pane (mixed-language
        // calls — a single English aside inside a Hebrew conversation
        // should still display LTR within its own line).
        let lineRTL = segment.text.isPredominantlyHebrew || language == "he"
        HStack(alignment: .top, spacing: 8) {
            if let sp = segment.speaker {
                Text(sp.friendlySpeakerLabel(language: language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(minWidth: 96, alignment: .leading)
            } else {
                Color.clear.frame(width: 96, height: 1)
            }
            Text(segment.text)
                .font(.callout)
                .foregroundStyle(segment.stable ? .primary : .secondary)
                .italic(!segment.stable)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .environment(\.layoutDirection, lineRTL ? .rightToLeft : .leftToRight)
    }
}

private struct ThinkingIndicator: View {
    let isThinking: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isThinking ? Color.purple : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
                .scaleEffect(pulse && isThinking ? 1.35 : 1.0)
                .animation(
                    isThinking
                        ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
            Text(isThinking ? "Thinking…" : "Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { pulse = true }
        .onChange(of: isThinking) { _, _ in pulse.toggle() }
    }
}
