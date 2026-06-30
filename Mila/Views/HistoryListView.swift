import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HistoryListView: View {
    let category: HistoryCategory
    let search: String
    @Binding var selection: SidebarSelection?

    @EnvironmentObject private var store: RecordingStore

    init(category: HistoryCategory,
         search: String = "",
         selection: Binding<SidebarSelection?>) {
        self.category = category
        self.search = search
        self._selection = selection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(category.displayName)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                BucketedRecordingsView(
                    recordings: store.recordings(in: category),
                    search: search,
                    selection: $selection
                )
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Force the ScrollView to fit the detail pane height instead of
        // expanding to its content's intrinsic height. Without this,
        // NavigationSplitView's column layout misaligned both the
        // detail pane and the sidebar (visible as the sidebar's
        // Home/Queue/More items being scrolled off the top of the
        // visible area).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Detail view for the sidebar's `.folder(name)` selection. Reuses the same
/// bucketed history layout so folder views look like the built-in categories.
struct FolderListView: View {
    let folderName: String
    let search: String
    @Binding var selection: SidebarSelection?

    @EnvironmentObject private var store: RecordingStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    Text(folderName).font(.title2.weight(.semibold))
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                BucketedRecordingsView(
                    recordings: store.recordings(inFolder: folderName),
                    search: search,
                    selection: $selection
                )
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("folder.list.\(folderName)")
    }
}

/// Detail view for the sidebar's `.defaultFolder` selection. Shows
/// everything the user hasn't filed away yet — the catch-all bucket that
/// replaces the old History categories.
struct DefaultFolderListView: View {
    let search: String
    @Binding var selection: SidebarSelection?

    @EnvironmentObject private var store: RecordingStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.fill").foregroundStyle(.tint)
                    Text("All Transcriptions").font(.title2.weight(.semibold))
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                BucketedRecordingsView(
                    recordings: store.unfiledRecordings(),
                    search: search,
                    selection: $selection
                )
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("folder.list.default")
    }
}

struct BucketedRecordingsView: View {
    let recordings: [Recording]
    let search: String
    @Binding var selection: SidebarSelection?

    var body: some View {
        let filtered = filterRecordings(recordings, search: search)
        let buckets = bucketByDate(filtered)

        if filtered.isEmpty {
            HStack {
                Spacer()
                emptyState
                Spacer()
            }
            .padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(buckets, id: \.label) { bucket in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bucket.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)

                        VStack(spacing: 0) {
                            ForEach(Array(bucket.items.enumerated()), id: \.element.id) { idx, rec in
                                HistoryRow(recording: rec, selection: $selection)
                                if idx < bucket.items.count - 1 {
                                    Divider().padding(.leading, 36)
                                }
                            }
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView(
                "Nothing here yet",
                systemImage: "tray",
                description: Text("New recordings will appear in this list.")
            )
        } else {
            ContentUnavailableView.search(text: search)
        }
    }
}

private struct HistoryRow: View {
    let recording: Recording
    @Binding var selection: SidebarSelection?

    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var llm: LLMSettings

    @State private var hovering = false
    @State private var renameRequest: String?
    @State private var promptForNewFolder = false
    @State private var newFolderDraft = ""
    @State private var showingSendSheet = false

    var body: some View {
        let isSelected: Bool = {
            if case .recording(let id) = selection, id == recording.id { return true }
            return false
        }()

        HStack(alignment: .top, spacing: 12) {
            RecordingSourceBadge(recording: recording, size: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recording.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(formatDuration(recording.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if !preview.isEmpty {
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    Text(recording.createdAt, format: .dateTime.hour().minute())
                    Text("·")
                    Text(recording.isZoomRecording ? "Zoom" : recording.source.displayName)
                    if transcription.activeRecordingID == recording.id {
                        Text("·")
                        ProgressView(value: transcription.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : (hovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { selection = .recording(recording.id) }
        // Trashed rows can't be dragged into a folder — they're already in
        // the bin, restoring them via drag would be a UX surprise. Other
        // rows carry their id as a `RecordingDragPayload` so the sidebar
        // folder rows can pick them up via `.dropDestination`.
        .draggable(recording.isTrashed
                   ? RecordingDragPayload(id: UUID())   // unused — won't be matched
                   : RecordingDragPayload(id: recording.id))
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.row.\(recording.title)")
        .sheet(item: Binding(
            get: { renameRequest.map(RenameDraft.init) },
            set: { if $0 == nil { renameRequest = nil } }
        )) { draft in
            RenameSheet(
                initialTitle: draft.title,
                onConfirm: { newTitle in
                    store.rename(recording, to: newTitle)
                    renameRequest = nil
                },
                onCancel: { renameRequest = nil }
            )
        }
        .sheet(isPresented: $promptForNewFolder) {
            FolderNameSheet(
                title: "New Folder",
                confirmLabel: "Create",
                name: $newFolderDraft,
                onConfirm: {
                    if let created = store.createFolder(newFolderDraft) {
                        store.assign(recording, toFolder: created)
                    }
                    promptForNewFolder = false
                },
                onCancel: { promptForNewFolder = false }
            )
        }
        .sheet(isPresented: $showingSendSheet) {
            SendToLLMSheet(recording: recording)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if recording.isTrashed {
            Button("Restore") { store.restore(recording) }
            Divider()
            Button("Delete Permanently", role: .destructive) {
                store.permanentlyDelete(recording)
                if case .recording(let id) = selection, id == recording.id {
                    selection = .home
                }
            }
        } else {
            Button("Rename…") {
                renameRequest = recording.title
            }
            Menu("Move to Folder") {
                Button(recording.folder == nil ? "✓ None" : "None") {
                    store.assign(recording, toFolder: nil)
                }
                if !store.folders.isEmpty {
                    Divider()
                    ForEach(store.folders, id: \.self) { folder in
                        Button(recording.folder == folder ? "✓ \(folder)" : folder) {
                            store.assign(recording, toFolder: folder)
                        }
                    }
                }
                Divider()
                Button("New Folder…") {
                    newFolderDraft = ""
                    promptForNewFolder = true
                }
            }
            Divider()
            let currentLang = RecordingLanguage.fromCode(recording.language)
            // Busy = this recording is already transcribing or queued. We gate
            // BEFORE mutating the store: `enqueue` drops active/queued ids, but
            // `prepareForRetranscription` persists `.pending`/language first, so
            // without this guard a re-transcribe on a busy row would clobber its
            // status even though the enqueue itself no-ops.
            let isBusy = transcription.activeRecordingID == recording.id
                || transcription.pendingIDs.contains(recording.id)
            Button("Re-transcribe (\(currentLang.flagEmoji) \(currentLang.displayName))") {
                // Route through the live-store chokepoint (same as the
                // language-switch action) so we never enqueue a stale snapshot
                // whose `.wav` a since-run compression already deleted.
                guard !isBusy,
                      let prepared = store.prepareForRetranscription(id: recording.id)
                else { return }
                transcription.enqueue(prepared)
            }
            .disabled(isBusy)
            Button("Re-transcribe in \(currentLang.other.flagEmoji) \(currentLang.other.displayName)") {
                retranscribe(recording, in: currentLang.other)
            }
            .disabled(isBusy)
            if llm.isConfigured {
                Divider()
                Button("Send to \(llm.tool.displayName)…") {
                    showingSendSheet = true
                }
                .disabled(recording.fullText.isEmpty && recording.segments.isEmpty)
            }
            Divider()
            Button("Export Subtitles (.srt)…") {
                exportSRT()
            }
            .disabled(recording.segments.isEmpty)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: recording)])
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.softDelete(recording)
                if case .recording(let id) = selection, id == recording.id {
                    selection = .home
                }
            }
        }
    }

    /// Switch the recording's stored language and re-enqueue it. The
    /// `TranscriptionService` reads `recording.language` to pick the right
    /// model (ivrit.ai for Hebrew, OpenAI for English), so updating the
    /// store before enqueueing is enough to re-run with the other model.
    private func retranscribe(_ recording: Recording, in language: RecordingLanguage) {
        // Gate before mutating the store: a busy (active/queued) recording must
        // not have its status/language flipped under an in-flight pass, because
        // `enqueue` would then no-op the re-run while the store mutation stuck.
        guard transcription.activeRecordingID != recording.id,
              !transcription.pendingIDs.contains(recording.id)
        else { return }
        // Mutate only language+status on the LIVE record so we don't clobber a
        // since-compressed `.m4a` audioFileName back to a deleted `.wav`.
        guard let prepared = store.prepareForRetranscription(id: recording.id,
                                                             language: language.rawValue)
        else { return }
        transcription.enqueue(prepared)
    }

    /// Save the recording's SRT to a user-chosen location. NSSavePanel lets
    /// the user place subtitles next to the original video file (the main
    /// "video → SRT" use case) or anywhere else they like. We use the
    /// title as the suggested filename so dragging a video produces
    /// `MyVideo.srt` next to `MyVideo.mp4` by default.
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

    private var preview: String {
        let t = recording.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 140 { return t }
        let end = t.index(t.startIndex, offsetBy: 140)
        return String(t[..<end]) + "…"
    }
}

private struct RenameDraft: Identifiable {
    let title: String
    var id: String { title }
}

struct RenameSheet: View {
    let initialTitle: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String

    init(initialTitle: String,
         onConfirm: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialTitle = initialTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _draft = State(initialValue: initialTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Recording").font(.title3.weight(.semibold))
            TextField("Title", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onConfirm(draft) }
                .accessibilityIdentifier("rename.title.field")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onConfirm(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("rename.title.save")
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

func filterRecordings(_ recs: [Recording], search: String) -> [Recording] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return recs }
    return recs.filter { r in
        r.title.lowercased().contains(q) || r.fullText.lowercased().contains(q)
    }
}

struct DateBucket {
    let label: String
    let items: [Recording]
}

func bucketByDate(_ recs: [Recording]) -> [DateBucket] {
    let cal = Calendar.current
    let now = Date()

    let weekdayFmt = DateFormatter()
    weekdayFmt.dateFormat = "EEEE"
    let dateFmt = DateFormatter()
    dateFmt.dateStyle = .long

    var todayItems: [Recording] = []
    var yesterdayItems: [Recording] = []
    var weekItems: [(key: String, recs: [Recording])] = []
    var olderItems: [(key: String, recs: [Recording])] = []

    func appendInto(_ list: inout [(key: String, recs: [Recording])], key: String, rec: Recording) {
        if let idx = list.firstIndex(where: { $0.key == key }) {
            list[idx].recs.append(rec)
        } else {
            list.append((key: key, recs: [rec]))
        }
    }

    for r in recs {
        let date = r.createdAt
        if cal.isDateInToday(date) {
            todayItems.append(r)
        } else if cal.isDateInYesterday(date) {
            yesterdayItems.append(r)
        } else if let days = cal.dateComponents([.day],
                                                from: cal.startOfDay(for: date),
                                                to: cal.startOfDay(for: now)).day,
                  days >= 0, days < 7 {
            appendInto(&weekItems, key: weekdayFmt.string(from: date), rec: r)
        } else {
            appendInto(&olderItems, key: dateFmt.string(from: date), rec: r)
        }
    }

    var buckets: [DateBucket] = []
    if !todayItems.isEmpty { buckets.append(DateBucket(label: "Today", items: todayItems)) }
    if !yesterdayItems.isEmpty { buckets.append(DateBucket(label: "Yesterday", items: yesterdayItems)) }
    for w in weekItems { buckets.append(DateBucket(label: w.key, items: w.recs)) }
    for o in olderItems { buckets.append(DateBucket(label: o.key, items: o.recs)) }
    return buckets
}
