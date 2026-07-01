import Foundation
import Combine
import OSLog

/// Bridges the iPhone Voice Memos library into Mila's transcription queue.
///
/// Responsibilities:
///  - **Backfill:** when the user enables sync or picks a new folder, import
///    every not-yet-seen recording from the selected folders and enqueue it.
///  - **Ongoing sync:** an FSEvents watcher on the Voice Memos folder notices
///    newly iCloud-synced recordings and imports the eligible ones.
///  - **Dedup:** every imported recording carries its `ZUNIQUEID` in
///    `Recording.voiceMemoUniqueID`; a rescan skips anything already present,
///    so restarts / repeated FSEvents bursts never re-import a memo.
///  - **Filtering:** short pocket recordings, `.qta` (unsupported format) and
///    `.composition` (multi-take) bundles are skipped, with counts surfaced.
///
/// Imports reuse `FileTranscriber.importFile`, which re-encodes into the
/// library and enqueues exactly like a drag-and-drop import — no new
/// transcription infrastructure.
@MainActor
final class VoiceMemosImporter: ObservableObject {
    private let store: RecordingStore
    private let transcription: TranscriptionService
    private let settings: VoiceMemosSettings
    private let languageSettings: RecordingLanguageSettings
    private let library: VoiceMemosLibrary

    private let log = MilaLog(category: "VoiceMemos")

    /// Last successful sync timestamp, for the Settings status line.
    @Published private(set) var lastSyncDate: Date?
    /// Recordings enqueued by the most recent sync.
    @Published private(set) var lastImportedCount = 0
    /// Cumulative recordings imported this session.
    @Published private(set) var totalImported = 0
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?

    private var watcher: DirectoryWatcher?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    /// Coalesces FSEvents bursts and overlapping triggers into one run.
    private var pendingResync = false

    init(store: RecordingStore,
         transcription: TranscriptionService,
         settings: VoiceMemosSettings,
         languageSettings: RecordingLanguageSettings,
         library: VoiceMemosLibrary = VoiceMemosLibrary()) {
        self.store = store
        self.transcription = transcription
        self.settings = settings
        self.languageSettings = languageSettings
        self.library = library
    }

    /// Wire up settings observation + the watcher, and run an initial sync.
    /// Called once from MilaApp's launch `.task`.
    func start() {
        guard !started else { return }
        started = true
        // React to the user toggling sync on/off or changing folder choices.
        // `objectWillChange` (rather than merging the `@Published` projections)
        // fires only on an actual change — no initial-value emissions to skip —
        // and the debounce coalesces dragging through several checkboxes into
        // one sync.
        settings.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reconfigure() }
            .store(in: &cancellables)

        reconfigure()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Apply the current settings: start/stop the watcher and trigger a sync.
    private func reconfigure() {
        guard settings.isEnabled, settings.hasSelection else {
            stop()
            return
        }
        // Sync is on and folders are chosen, but the library may still be
        // unreadable. Log *why* rather than silently bailing — a TCC / Full
        // Disk Access denial is the one failure that otherwise leaves no
        // trace in the logs at all (issue #45).
        switch library.availability {
        case .available:
            break
        case .databaseMissing:
            log.notice("VoiceMemos sync is enabled but no library was found at \(self.library.databaseDisplayPath, privacy: .public) — nothing to sync (iCloud sync off, or no recordings yet).")
            stop()
            return
        case .accessDenied(let reason):
            log.error("VoiceMemos sync is enabled but macOS denied access to \(self.library.databaseDisplayPath, privacy: .public) (\(reason, privacy: .public)). Grant Mila Full Disk Access in System Settings → Privacy & Security → Full Disk Access.")
            lastError = VoiceMemosLibrary.LibraryError.accessDenied(reason).localizedDescription
            stop()
            return
        }
        startWatcherIfNeeded()
        requestSync()
    }

    private func startWatcherIfNeeded() {
        guard watcher == nil else { return }
        let watcher = DirectoryWatcher(path: library.recordingsDirectory.path) { [weak self] in
            // FSEvents fires on a background queue; hop to the main actor.
            Task { @MainActor in self?.requestSync() }
        }
        watcher.start()
        self.watcher = watcher
        log.log("VoiceMemos watcher started on \(self.library.recordingsDirectoryDisplayPath, privacy: .public)")
    }

    /// Public entry point for the "Rescan now" button in Settings.
    func rescan() { requestSync() }

    /// Run a sync, coalescing requests so two never overlap.
    private func requestSync() {
        guard !isSyncing else {
            pendingResync = true
            return
        }
        Task { await sync() }
    }

    private func sync() async {
        guard settings.isEnabled, settings.hasSelection else { return }
        isSyncing = true
        lastError = nil
        defer {
            isSyncing = false
            // A folder change / FSEvents burst that arrived mid-sync set
            // `pendingResync`; kick the next pass now that `isSyncing` is
            // clear (doing this before clearing it would just re-set the flag
            // and the second pass would never run).
            if pendingResync {
                pendingResync = false
                requestSync()
            }
        }

        let folderUUIDs = settings.selectedFolderUUIDs
        let includeUnfiled = settings.includeUnfiled

        // Read the (private, WAL-mode) DB off the main actor.
        let lib = library
        let memos: [VoiceMemosLibrary.Memo]
        do {
            memos = try await Task.detached(priority: .utility) {
                try lib.recordings(folderUUIDs: folderUUIDs, includeUnfiled: includeUnfiled)
            }.value
        } catch {
            lastError = error.localizedDescription
            log.error("VoiceMemos sync failed reading DB: \(error.localizedDescription, privacy: .public)")
            return
        }

        let alreadyImported = Set(store.recordings.compactMap { $0.voiceMemoUniqueID })
        let fm = FileManager.default

        var imported = 0
        var skippedShort = 0, skippedFormat = 0, skippedComposition = 0, skippedMissing = 0

        for memo in memos where !alreadyImported.contains(memo.uniqueID) {
            if memo.isComposition { skippedComposition += 1; continue }
            if memo.isUnsupportedFormat { skippedFormat += 1; continue }
            if memo.duration < VoiceMemosSettings.minDurationSeconds { skippedShort += 1; continue }
            guard fm.fileExists(atPath: memo.fileURL.path) else {
                // Not downloaded from iCloud yet (or evicted); a later
                // FSEvents fire will catch it once it lands.
                skippedMissing += 1
                continue
            }

            do {
                let recording = try await FileTranscriber.importFile(
                    at: memo.fileURL,
                    into: store,
                    language: languageSettings.current,
                    source: .voiceMemo,
                    title: memo.title,
                    createdAt: memo.date,
                    voiceMemoUniqueID: memo.uniqueID
                )
                transcription.enqueue(recording)
                imported += 1
            } catch {
                log.error("VoiceMemos import failed for \(memo.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        lastImportedCount = imported
        totalImported += imported
        lastSyncDate = Date()
        log.log("VoiceMemos sync: imported \(imported), skipped short=\(skippedShort) format=\(skippedFormat) composition=\(skippedComposition) missing=\(skippedMissing)")
    }
}
