import SwiftUI
import AppKit

/// Settings → Storage. Lets the user redirect new recordings (and their
/// `recordings.json` / sidecar metadata) to a directory of their choosing
/// — typical use cases are `~/Documents/Meetings`, an external drive, or
/// a cloud-sync folder (Dropbox, iCloud Drive, Google Drive).
///
/// The chosen folder is persisted via a security-scoped bookmark; see
/// `RecordingStorageSettings` for the resolution / fallback rules.
///
/// Picking a new directory swaps the in-flight `RecordingStore` over to it
/// — new recordings land in the new folder immediately, and the sidebar
/// re-scans the new location for any pre-existing `recordings.json`.
/// Old recordings stay where they were on disk; this tab does **not**
/// move them, by design (a multi-GB copy on the main thread is not a
/// thing we want to do during a settings change). The user can hand-
/// move them or use the "Move existing recordings…" affordance below.
struct StorageSettingsTab: View {
    @EnvironmentObject private var storage: RecordingStorageSettings
    @EnvironmentObject private var store: RecordingStore
    /// Watched so the "Choose…" / "Reset" affordances can refuse to
    /// relocate mid-recording — see `applyChosenDirectory` for the
    /// failure mode this guards (in-flight WAV orphaned in the old
    /// directory after the store flips its `recordingsDirectory`).
    @EnvironmentObject private var actions: QuickActionsController

    @State private var lastError: String?
    @State private var isCompressing = false
    @State private var compressStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            currentLocationCard
            storageLimitCard
            if storage.lastResolutionWasStale {
                staleBookmarkNotice
            }
            if let lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recordings location")
                .font(.title3.weight(.semibold))
            Text("New voice memos, dictations, and meeting transcripts are saved here together with their metadata. Existing recordings stay where they were — pick a new folder and Mila re-scans it for any prior content, otherwise it starts fresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentLocationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayPath(store.recordingsDirectory))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(isCustom ? "Custom location" : "Default location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Choose…") { chooseFolder() }
                    .disabled(actions.isRecording)
                    .help(actions.isRecording
                          ? "Stop the current recording to change the storage location"
                          : "Pick a folder for new recordings")
                    .accessibilityIdentifier("storage.chooseFolder.button")
                Button("Reveal in Finder") { revealInFinder() }
                Spacer()
                Button("Reset to default") { resetToDefault() }
                    .disabled(!isCustom || actions.isRecording)
                    .help(actions.isRecording
                          ? "Stop the current recording to reset the storage location"
                          : "Use the default Application Support location")
                    .accessibilityIdentifier("storage.resetDefault.button")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Storage cap: a stepper for the GB limit + the current usage. New
    /// recordings are blocked at the cap (see
    /// `QuickActionsController.storageCapReached`); existing recordings
    /// are never auto-deleted.
    private var storageLimitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(.tint)
                Text("Storage limit")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(usageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper(value: Binding(get: { storage.limitGigabytes },
                                   set: { storage.limitGigabytes = $0 }),
                    in: 1...500, step: 1) {
                Text("Cap new recordings at \(Int(storage.limitGigabytes.rounded())) GB")
                    .font(.callout)
            }
            Text("New recordings are blocked once the library reaches this size. Existing recordings are never deleted automatically — reclaim space below or raise the limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 8) {
                Button { compressExisting() } label: {
                    if isCompressing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(compressStatus ?? "Compressing…")
                        }
                    } else {
                        Text("Compress existing recordings")
                    }
                }
                .disabled(isCompressing || actions.isRecording || store.wavRecordingCount() == 0)
                .help(actions.isRecording
                      ? "Stop the current recording before compressing"
                      : "Transcode older WAV recordings to m4a to reclaim disk space")
                .accessibilityIdentifier("storage.compressExisting.button")
                Spacer()
                Text(isCompressing ? (compressStatus ?? "") : reclaimSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var reclaimSummary: String {
        let n = store.wavRecordingCount()
        if n == 0 { return "All recordings compressed" }
        return "\(n) WAV recording\(n == 1 ? "" : "s") can be compressed"
    }

    private func compressExisting() {
        guard !isCompressing, !actions.isRecording else { return }
        isCompressing = true
        compressStatus = "Starting…"
        Task { @MainActor in
            let total = await store.compressAllWAVRecordings { done, count in
                compressStatus = "Compressed \(done) of \(count)…"
            }
            isCompressing = false
            compressStatus = total > 0 ? "Compressed \(total) recording\(total == 1 ? "" : "s")." : nil
        }
    }

    private var usageSummary: String {
        let usedGB = Double(store.currentUsageBytes()) / 1_073_741_824.0
        return String(format: "%.2f GB used", usedGB)
    }

    private var staleBookmarkNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The folder you previously chose was moved or renamed. Mila refreshed the saved reference — if recordings look missing, pick the folder again to be sure.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var isCustom: Bool {
        storage.customDirectory != nil
    }

    private func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func chooseFolder() {
        lastError = nil
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for new recordings"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = storage.customDirectory ?? store.recordingsDirectory
        // Show modal — Settings is its own window, so a sheet-style
        // presentation feels off; the standard open panel matches the
        // pattern other macOS apps use for their "pick a folder"
        // affordances.
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        applyChosenDirectory(url)
    }

    private func applyChosenDirectory(_ url: URL) {
        // Refuse to relocate while a recording is in progress. The
        // in-flight WAV is being written to the OLD
        // `recordingsDirectory` (the URL was resolved at recording
        // start via `freshAudioURL`); after `relocateRecordings`,
        // `store.audioURL(for:)` would resolve under the NEW
        // directory, so `stopRecording → store.add` would register a
        // recording whose audio file physically lives at a stale
        // path. Playback and transcription would both fail with the
        // file missing. Bugbot finding on PR #26.
        if actions.isRecording {
            lastError = "A recording is in progress. Stop the recording before changing the storage location."
            return
        }
        // Don't allow picking the model cache — it's inside the
        // Application Support tree and the user almost certainly
        // didn't mean to mix recordings into it. Trying to do that
        // would also break in subtle ways because we'd start treating
        // model files as orphan recordings.
        if url.path == store.modelsDirectory.path {
            lastError = "That folder is reserved for whisper models. Please pick a different location."
            return
        }
        guard storage.setDirectory(url) else {
            lastError = "Couldn't save that folder. Try a different location (some network/cloud volumes can't be bookmarked)."
            return
        }
        store.relocateRecordings(to: storage.customDirectory)
    }

    private func resetToDefault() {
        // Same recording-in-progress guard as applyChosenDirectory —
        // resetting also calls `store.relocateRecordings(to:)`, which
        // would orphan an in-flight WAV at the previous custom
        // location.
        if actions.isRecording {
            lastError = "A recording is in progress. Stop the recording before resetting the storage location."
            return
        }
        lastError = nil
        storage.clearDirectory()
        store.relocateRecordings(to: nil)
    }

    private func revealInFinder() {
        // Open the directory itself in a Finder window. We can't use
        // `activateFileViewerSelecting([url])` because that highlights
        // the directory inside its parent — handy for files, but for
        // a folder the user usually wants to step _into_ it.
        NSWorkspace.shared.open(store.recordingsDirectory)
    }
}
