import SwiftUI
import AVKit
import AppKit
import TranscriptionCore
import UniformTypeIdentifiers

struct RecordingDetailView: View {
    let recording: Recording
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var modelManager: ModelManager

    @State private var player: AVPlayer?
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AIOverviewSection(
                summary: recording.summary,
                items: recording.actionItems ?? [],
                recordingLanguage: recording.language
            )
            transcriptArea
                // Force the transcript area to take the remaining
                // vertical space and scroll its OWN content rather than
                // expanding to the segments' intrinsic height. Without
                // this, a transcript with many segments made the VStack
                // grow to ~1500 px in a 700 px window and the content
                // overflowed upward past the title bar, leaving the
                // user with a blank window. Reproduced via accessibility
                // tree inspection.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            playbackBar
        }
        // ContentView applies .id(rec.id) at the call site, so SwiftUI
        // rebuilds this view on navigation between recordings and we don't
        // need a separate onChange handler to reconfigure the player.
        .onAppear { configurePlayer() }
        .onDisappear { teardownPlayer() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                titleEditor
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        RecordingSourceBadge(recording: recording, size: 18)
                        Text(recording.isZoomRecording
                             ? "Zoom"
                             : recording.source.displayName)
                    }
                    Text("·")
                    Text(recording.createdAt, format: .dateTime)
                    Text("·")
                    Text(formatDuration(recording.duration))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            actionButtons
        }
        .padding()
    }

    /// Click-to-edit title. Pressing Return or losing focus commits the new
    /// title via `store.rename`. Escape reverts without saving. The display
    /// state intentionally does not look like a TextField until the user
    /// clicks it — we don't want a 20pt input bar dominating the header.
    @ViewBuilder
    private var titleEditor: some View {
        if isEditingTitle {
            TextField("Title", text: $titleDraft)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.roundedBorder)
                .focused($titleFieldFocused)
                .onSubmit { commitTitle() }
                .onExitCommand { cancelTitleEdit() }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .accessibilityIdentifier("detail.title.field")
        } else {
            Text(recording.title)
                .font(.title2.weight(.semibold))
                .contentShape(Rectangle())
                .onTapGesture { beginTitleEdit() }
                .help("Click to rename")
                .accessibilityIdentifier("detail.title.label")
        }
    }

    private func beginTitleEdit() {
        titleDraft = recording.title
        isEditingTitle = true
        // Defer focus to next runloop tick so the TextField is actually in
        // the view hierarchy before we ask it to grab keyboard focus.
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != recording.title {
            store.rename(recording, to: trimmed)
        }
        isEditingTitle = false
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
        titleDraft = recording.title
    }

    private var actionButtons: some View {
        let currentLang = RecordingLanguage.fromCode(recording.language)
        let busy = transcription.activeRecordingID == recording.id
                   || transcription.pendingIDs.contains(recording.id)
        return HStack {
            Menu {
                Button {
                    transcription.enqueue(recording)
                } label: {
                    Label("\(currentLang.flagEmoji) \(currentLang.displayName) (current)",
                          systemImage: "arrow.clockwise")
                }
                Button {
                    retranscribe(in: currentLang.other)
                } label: {
                    Label("\(currentLang.other.flagEmoji) \(currentLang.other.displayName)",
                          systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Label(recording.status == .completed ? "Re-transcribe" : "Transcribe",
                      systemImage: "text.badge.checkmark")
            }
            .disabled(busy)

            ShareLink(item: store.audioURL(for: recording)) {
                Label("Share audio", systemImage: "square.and.arrow.up")
            }

            Button {
                copyTranscript()
            } label: {
                Label("Copy transcript", systemImage: "doc.on.doc")
            }
            .disabled(recording.fullText.isEmpty)

            Button {
                exportSRT()
            } label: {
                Label("Export Subtitles", systemImage: "captions.bubble")
            }
            .disabled(recording.segments.isEmpty)
            .help("Save subtitles (.srt) for the original video/audio")
        }
    }

    /// Save the SRT file to a user-chosen location. Defaulting the filename
    /// to the recording title makes the common case (drag video in → save
    /// `MyVideo.srt` next to `MyVideo.mp4`) one click.
    private func exportSRT() {
        let panel = NSSavePanel()
        panel.title = "Export Subtitles"
        panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .data]
        panel.nameFieldStringValue = recording.title + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExporter.writeSRT(for: recording, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Re-run the transcription pipeline with a different language model.
    /// Updates the persisted `Recording.language` so the downstream
    /// `TranscriptionService` picks the right model on its own.
    private func retranscribe(in language: RecordingLanguage) {
        var copy = recording
        copy.language = language.rawValue
        copy.status = .pending
        store.update(copy)
        transcription.enqueue(copy)
    }


    /// Human-readable name of the whisper model that will run for the
    /// recording's CURRENT language. Prefers `recording.modelName` once
    /// transcription has started writing it back to the store (that's
    /// what the engine actually used), otherwise falls back to the
    /// model selected for the recording's language.
    private var activeTranscriptionModelName: String {
        if let name = recording.modelName, !name.isEmpty { return name }
        if let model = modelManager.model(for: recording.language) {
            return model.displayName
        }
        return modelManager.selectedModel()?.displayName ?? ""
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if transcription.activeRecordingID == recording.id {
            VStack(spacing: 12) {
                Spacer()
                ProgressView(value: transcription.progress) {
                    // Use the model for THIS recording's language, not
                    // `modelManager.selectedModel()` (the user's
                    // global default). Otherwise re-transcribing a
                    // recording in English while the user has Hebrew
                    // pinned globally still says "Transcribing with
                    // ivrit-ai…" while actually running OpenAI Turbo,
                    // which was the bug reported.
                    Text("Transcribing with \(activeTranscriptionModelName)…")
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)
                Text("\(Int(transcription.progress * 100))%")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if recording.segments.isEmpty {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "text.alignleft",
                description: Text("Click \(Image(systemName: "text.badge.checkmark")) Transcribe to start.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    // Show the speaker column whenever ANY segment has a
                    // speaker label — that's how the user knows
                    // diarization actually ran for this recording.
                    // Dictation segments have nil speakers, so they
                    // naturally hide the column; a meeting where
                    // pyannote found only 1 speaker still shows
                    // "Speaker A" so the user gets feedback that the
                    // detection ran (vs. silently failing to detect).
                    let hasSpeakers = recording.segments.contains { $0.speaker != nil }
                    ForEach(recording.segments) { seg in
                        SegmentRow(segment: seg,
                                   isActive: currentTime >= seg.start && currentTime < seg.end,
                                   showSpeaker: hasSpeakers,
                                   language: recording.language,
                                   onTap: { seek(to: seg.start) })
                    }
                }
                .padding()
                .environment(\.layoutDirection, recording.language == "he" ? .rightToLeft : .leftToRight)
            }
            .contextMenu {
                let other = RecordingLanguage.fromCode(recording.language).other
                Button("Re-transcribe in \(other.flagEmoji) \(other.displayName)") {
                    retranscribe(in: other)
                }
                Button("Copy transcript") { copyTranscript() }
                    .disabled(recording.fullText.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var playbackBar: some View {
        if let player {
            HStack {
                PlayPauseButton(player: player)
                Slider(value: Binding(get: { currentTime },
                                      set: { seek(to: $0) }),
                       in: 0...max(recording.duration, 0.1))
                Text(formatDuration(currentTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding()
        }
    }

    private func configurePlayer() {
        teardownPlayer()
        let url = store.audioURL(for: recording)
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30),
                                                  queue: .main) { time in
            currentTime = time.seconds.isFinite ? time.seconds : 0
        }
        player = p
    }

    private func teardownPlayer() {
        if let player, let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    private func copyTranscript() {
        let text = TranscriptFormatter.plainText(segments: recording.segments,
                                                 fallback: recording.fullText)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct PlayPauseButton: View {
    let player: AVPlayer
    /// Stable local state. The previous design wrapped the player in a
    /// `PlayerBridge` ObservableObject and used `@ObservedObject`,
    /// which RE-INSTANTIATED the bridge (and a fresh KVO observer)
    /// on every parent re-render. As soon as playback started, the
    /// time observer in `configurePlayer` fired ~30×/sec and forced
    /// re-renders of the playback bar — each one tore down the old
    /// bridge, briefly read `timeControlStatus == .paused` while the
    /// new bridge was warming up, and flipped the icon back to "play"
    /// for one frame before the KVO callback caught up. Hence the
    /// flicker. Owning a plain @State Bool + a single long-lived
    /// observer in onAppear is enough.
    @State private var isPlaying: Bool = false
    @State private var observer: NSKeyValueObservation?

    var body: some View {
        Button {
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderedProminent)
        .onAppear {
            isPlaying = (player.timeControlStatus == .playing)
            // KVO on timeControlStatus is enough — fires on every
            // transition between paused / waiting / playing.
            observer = player.observe(\.timeControlStatus, options: [.new]) { p, _ in
                DispatchQueue.main.async {
                    isPlaying = (p.timeControlStatus == .playing)
                }
            }
        }
        .onDisappear {
            observer?.invalidate()
            observer = nil
        }
    }
}

/// Live-AI summary + action items, captured at recording stop time and
/// persisted onto the Recording. Extracted into its own `View` rather
/// than a `@ViewBuilder` var on the parent so the body's type inference
/// is contained: a SwiftUI hiccup inside this section never silently
/// blanks the rest of the detail screen, which is the symptom the user
/// was hitting when both the sidebar and the detail pane went empty
/// after transcription completed.
private struct AIOverviewSection: View {
    let summary: String?
    let items: [ActionItem]
    let recordingLanguage: String

    /// Hide the whole section when there's nothing to show. Old
    /// recordings + non-Live-AI recordings simply collapse this to an
    /// EmptyView so the detail screen doesn't have an empty gap above
    /// the transcript.
    private var hasContent: Bool {
        (summary?.isEmpty == false) || !items.isEmpty
    }

    /// Section-level RTL decision: prefer the actual text content
    /// because the language dropdown may have been left on English
    /// while the conversation happened in Hebrew.
    private var sectionIsRTL: Bool {
        let blob = (summary ?? "") + " " + items.map(\.text).joined(separator: " ")
        return blob.isPredominantlyHebrew || recordingLanguage == "he"
    }

    var body: some View {
        if hasContent {
            // Use explicit `.trailing` alignment for Hebrew rather than
            // flipping `\.layoutDirection`. The environment approach
            // made the ScrollView mis-measure its frame when the
            // sidebar was open — the Hebrew block ended up shifted
            // LEFT of the pane by the sidebar's width. Same fix
            // pattern as `LiveAIRecordingView.liveTranscriptPane`.
            let alignmentValue: Alignment = sectionIsRTL ? .trailing : .leading
            let multilineAlignment: TextAlignment = sectionIsRTL ? .trailing : .leading
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let summary, !summary.isEmpty {
                            summaryView(summary,
                                        alignment: alignmentValue,
                                        multiline: multilineAlignment)
                        }
                        if !items.isEmpty {
                            actionItemsView(alignment: alignmentValue,
                                            multiline: multilineAlignment)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: alignmentValue)
                }
                // Hard cap so a recording with many action items or a
                // long summary can NEVER push the transcript /
                // playback bar off-screen. The inner content scrolls
                // independently inside this slot if it exceeds 240 pt.
                .frame(maxHeight: 240)
                Divider()
            }
        }
    }

    private func summaryView(_ text: String,
                             alignment: Alignment,
                             multiline: TextAlignment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Summary", systemImage: "sparkles")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment)
                .multilineTextAlignment(multiline)
        }
    }

    private func actionItemsView(alignment: Alignment,
                                 multiline: TextAlignment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Action items", systemImage: "checklist")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    ActionItemDetailRow(text: item.text,
                                        alignment: alignment,
                                        multiline: multiline)
                }
            }
        }
    }
}

private struct ActionItemDetailRow: View {
    let text: String
    let alignment: Alignment
    let multiline: TextAlignment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment)
                .multilineTextAlignment(multiline)
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let showSpeaker: Bool
    /// Recording's language so we can render the raw `SPEAKER_00`
    /// label from pyannote as `Speaker A` / `דובר א׳` in the user's
    /// language — matching the labels the live view + post-recording
    /// action items already show.
    let language: String
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Speaker prefix sits TIGHT against the text — fixed-width
            // columns introduced a gap (~30 pt) between the friendly
            // label "Speaker A" / "דובר א׳" and the actual content.
            // `fixedSize` keeps the label at its natural width.
            if showSpeaker, let raw = segment.speaker, !raw.isEmpty {
                Text(raw.friendlySpeakerLabel(language: language) + ":")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(segment.text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatDuration(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
