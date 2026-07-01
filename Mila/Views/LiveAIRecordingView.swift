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
    // NOTE: `session` is deliberately NOT observed here. RecordingSession
    // is a fat ObservableObject that also @Publishes micLevel/systemLevel
    // at ~50 Hz; holding it here re-evaluated this whole body (including
    // the growing transcript ForEach) on every mic-level tick. The
    // elapsed clock now lives in the `RecordingElapsedLabel` leaf so only
    // that tiny Text re-renders at audio cadence — not the transcript.
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

    /// RTL for the AI pane (summary + action items). The AI output is its
    /// own language setting; for `.auto` we detect from the actual emitted
    /// text — summary + ALL item texts combined — so a short individual
    /// item with an embedded English name ("…ל-Cursor") doesn't mis-detect
    /// while its neighbours are clearly Hebrew. One verdict for the whole
    /// pane keeps every row aligned the same way. Drives EXPLICIT
    /// `.trailing` alignment (never `\.layoutDirection`) — see the live
    /// transcript pane: flipping layoutDirection mis-measured inside the
    /// split view / open sidebar and shoved Hebrew to the left.
    private var aiOutputIsRTL: Bool {
        switch liveAISettings.outputLanguage {
        case .hebrew: return true
        case .english: return false
        case .auto:
            if language == "he" { return true }
            let combined = aiSession.summary + " "
                + aiSession.actionItems.map(\.text).joined(separator: " ")
            return combined.isPredominantlyHebrew
        }
    }

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
            // Stable handle for the audio-loopback E2E to drive Stop (the
            // record-while-finalizing regression test taps this, then polls
            // the Home Record button to confirm it isn't stuck "Finalizing").
            .accessibilityIdentifier("liveAI.stop")

            VStack(alignment: .leading, spacing: 2) {
                Text(aiActive ? "Recording — Live AI" : "Recording")
                    .font(.callout.weight(.semibold))
                RecordingElapsedLabel()
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
                let rtl = aiOutputIsRTL
                ScrollView {
                    VStack(alignment: rtl ? .trailing : .leading, spacing: 18) {
                        if !aiSession.summary.isEmpty {
                            summarySection(isRTL: rtl)
                        }
                        if !aiSession.actionItems.isEmpty {
                            actionItemsSection(isRTL: rtl)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
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
    private func summarySection(isRTL: Bool) -> some View {
        let bullets = Self.bulletsFromSummary(aiSession.summary)
        return VStack(alignment: isRTL ? .trailing : .leading, spacing: 6) {
            sectionHeader(icon: "text.alignleft", title: "Summary", isRTL: isRTL)
            VStack(alignment: isRTL ? .trailing : .leading, spacing: 4) {
                ForEach(bullets, id: \.self) { line in
                    BulletLine(text: line, isRTL: isRTL)
                }
            }
            // Aggregate accessibility node — the UI test reads this
            // single element's label to verify LLM summary populated.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("liveAI.summary")
        }
        .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
    }

    private func actionItemsSection(isRTL: Bool) -> some View {
        VStack(alignment: isRTL ? .trailing : .leading, spacing: 6) {
            sectionHeader(icon: "checklist", title: "Action items", isRTL: isRTL)
            VStack(alignment: isRTL ? .trailing : .leading, spacing: 4) {
                ForEach(aiSession.actionItems) { item in
                    ActionItemRow(item: item, language: language, isRTL: isRTL)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
    }

    /// Section header (icon + label). For RTL the icon sits on the right
    /// of the label and the whole header pins to the trailing edge, so it
    /// reads with the Hebrew content below it.
    private func sectionHeader(icon: String, title: String, isRTL: Bool) -> some View {
        HStack(spacing: 4) {
            if isRTL {
                Text(title).font(.callout.weight(.semibold))
                Image(systemName: icon).foregroundStyle(.tint)
            } else {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(title).font(.callout.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
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
                    // LazyVStack (not VStack): a plain VStack lays out
                    // every segment on each invalidation, so per-tick cost
                    // grew ~linearly with recording length. Lazy keeps it
                    // O(visible) — flat regardless of transcript size.
                    LazyVStack(alignment: .leading, spacing: 6) {
                        let _ = MilaLog(category: "LiveAIRecordingView")
                            .log("render segments.count=\(transcriber.segments.count, privacy: .public)")
                        if transcriber.segments.isEmpty {
                            Text("Listening…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: textAlignment)
                                .accessibilityIdentifier("liveTranscript.listening")
                        } else {
                            ForEach(transcriber.segments) { seg in
                                TranscriptLineView(segment: seg, language: language)
                                    .frame(maxWidth: .infinity, alignment: textAlignment)
                                // Identifier is applied to the inner Text
                                // inside TranscriptLineView (where SwiftUI
                                // actually creates a staticText a11y node).
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("transcript-body")
                    // Intentionally NOT setting accessibilityIdentifier
                    // here: when this VStack has a single child SwiftUI
                    // collapses the wrapper into the child's a11y
                    // element, and the parent identifier overrides any
                    // identifier set on the child (e.g. on
                    // `Text("Listening…")` or on each
                    // `Text(segment.text)` inside TranscriptLineView).
                    // The XCUITest queries for `liveTranscript.listening`
                    // / `liveTranscript.segment` were silently failing
                    // because both leaves ended up as
                    // `liveTranscript.container` in the tree. The
                    // identifier was only here for diagnostics and isn't
                    // queried in production.
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
    /// Decided by the AI pane (one verdict for all rows), not per-line —
    /// drives EXPLICIT alignment rather than `\.layoutDirection`, which
    /// mis-measured inside the split view and shoved Hebrew left.
    var isRTL: Bool = false

    var body: some View {
        let bullet = Text("•")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
        let label = Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
            .multilineTextAlignment(isRTL ? .trailing : .leading)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isRTL { label; bullet } else { bullet; label }
        }
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let language: String
    /// Decided once by the AI pane for all items (so they align
    /// consistently), driving EXPLICIT `.trailing` alignment. We do NOT
    /// flip `\.layoutDirection` — that mis-measured inside the split view
    /// / open sidebar and shoved Hebrew action items to the left, which
    /// is the bug this replaces.
    var isRTL: Bool = false

    var body: some View {
        let align: Alignment = isRTL ? .trailing : .leading
        let textAlign: TextAlignment = isRTL ? .trailing : .leading
        let bullet = Text("•")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
        let content = VStack(alignment: isRTL ? .trailing : .leading, spacing: 4) {
            Text(item.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: align)
                .multilineTextAlignment(textAlign)
            if hasMetadata {
                metadataRow
                    .frame(maxWidth: .infinity, alignment: align)
            }
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isRTL { content; bullet } else { bullet; content }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var metadataRow: some View {
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

    private var hasMetadata: Bool {
        item.speaker != nil || item.timestampSeconds > 0 || item.source == .voiceCommand
    }

    private func formatTimestamp(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Leaf that owns the only dependency on `RecordingSession`, so the
/// session's high-frequency @Published updates (elapsed at 5 Hz,
/// micLevel/systemLevel at ~50 Hz) re-render ONLY this small Text rather
/// than the whole `LiveAIRecordingView` body (which holds the growing
/// transcript). The mm:ss display rounds to whole seconds, so the extra
/// audio-cadence updates here are cheap and invisible.
private struct RecordingElapsedLabel: View {
    @EnvironmentObject private var session: RecordingSession

    var body: some View {
        let t = Int(session.elapsed.rounded())
        Text(String(format: "%02d:%02d", t / 60, t % 60))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
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
                // Put the identifier on the leaf Text so XCUITest's
                // `.staticTexts.matching(identifier:)` finds it. The
                // outer wrapper-level identifier was a no-op (SwiftUI
                // didn't materialize an a11y node there).
                .accessibilityIdentifier("liveTranscript.segment")
        }
        .environment(\.layoutDirection, lineRTL ? .rightToLeft : .leftToRight)
    }
}

private struct ThinkingIndicator: View {
    let isThinking: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Use AppKit's indeterminate spinner while thinking instead of a
            // SwiftUI `.repeatForever` scaleEffect. The old pulse animation
            // never stopped (a repeatForever keyed on a @State `pulse` keeps
            // interpolating regardless of the current `isThinking`), which
            // pinned the main thread: SwiftUI re-ran the animation + layout
            // pipeline every frame, cascading into a full re-layout of the
            // whole recording screen — including the transcript ScrollView —
            // at ~60fps even at idle (confirmed via a process sample: a
            // continuous AnimatableAttribute/NSHostingView.layout storm).
            // NSProgressIndicator animates in its own layer and does NOT
            // drive the SwiftUI view graph, so it spins for free.
            if isThinking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
            }
            Text(isThinking ? "Thinking…" : "Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
