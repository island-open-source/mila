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
            transcriptArea
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

    @ViewBuilder
    private var transcriptArea: some View {
        if transcription.activeRecordingID == recording.id {
            VStack(spacing: 12) {
                Spacer()
                ProgressView(value: transcription.progress) {
                    Text("Transcribing with \(modelManager.selectedModel()?.displayName ?? "")…")
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
                    let hasSpeakers = recording.segments.contains { $0.speaker != nil }
                    ForEach(recording.segments) { seg in
                        SegmentRow(segment: seg,
                                   isActive: currentTime >= seg.start && currentTime < seg.end,
                                   showSpeaker: hasSpeakers,
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
    @ObservedObject private var bridge: PlayerBridge

    init(player: AVPlayer) {
        _bridge = ObservedObject(wrappedValue: PlayerBridge(player: player))
    }

    var body: some View {
        Button {
            bridge.toggle()
        } label: {
            Image(systemName: bridge.isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderedProminent)
    }
}

@MainActor
private final class PlayerBridge: ObservableObject {
    @Published var isPlaying = false
    let player: AVPlayer
    private var token: NSKeyValueObservation?

    init(player: AVPlayer) {
        self.player = player
        token = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.isPlaying = (p.timeControlStatus == .playing)
            }
        }
    }
    func toggle() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let showSpeaker: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(formatDuration(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            if showSpeaker {
                Text(segment.speaker ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 72, alignment: .leading)
            }
            Text(segment.text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
