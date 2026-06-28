import Foundation
import Combine
import OSLog

private let recStoreLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "RecordingStore")

/// Persists recordings + their metadata under Application Support/Mila.
///
/// Two pre-rename locations exist:
///   1. `Application Support/IvritWhisper` (the original product name).
///   2. `Application Support/IslandWhisper` (the second product name).
/// On first launch we transparently migrate from whichever of those
/// exists into the new `Application Support/Mila` directory so users
/// don't lose their already-downloaded models (~4.6 GB combined) or
/// recordings. IslandWhisper takes precedence over IvritWhisper when
/// both are somehow present (the user's latest data lives there).
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    /// Folder names the user has explicitly created. Kept separate from the
    /// set derived from `recordings[*].folder` so an empty folder still shows
    /// up in the sidebar and survives moving its last recording elsewhere.
    @Published private(set) var folders: [String] = []

    private let fileManager = FileManager.default
    /// `storeURL` and `foldersURL` move with `recordingsDirectory` on
    /// every `relocateRecordings` call. On the default path they live
    /// alongside the `Recordings/` subdir (legacy layout); on a custom
    /// path they live inside the chosen folder so the user-picked
    /// directory is self-contained (one folder == recordings + their
    /// metadata, portable across machines / cloud sync).
    private(set) var storeURL: URL
    private(set) var foldersURL: URL
    /// Published so the Settings UI's "Current location" row updates the
    /// moment the user picks a different folder.
    @Published private(set) var recordingsDirectory: URL
    let modelsDirectory: URL
    /// The default recordings location (always inside Application
    /// Support/Mila/Recordings). Used by Settings to label the
    /// "Reset to default" button and to detect when a custom path is in
    /// effect.
    let defaultRecordingsDirectory: URL

    convenience init() {
        // UI tests pass --ui-test-clean-store to bypass the user's real
        // Application Support directory and start from a fresh, deterministic
        // state. We honor it before touching the real path so a test run
        // never reads or writes the user's recordings.
        if CommandLine.arguments.contains("--ui-test-clean-store") {
            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("Mila-UITest-\(UUID())", isDirectory: true)
            self.init(rootDirectory: tmpRoot)
            if CommandLine.arguments.contains("--ui-test-seed-recording") {
                let seed = Recording(
                    title: "Seed Recording",
                    duration: 1.5,
                    source: .microphone,
                    audioFileName: "seed.wav",
                    status: .completed,
                    language: "en",
                    fullText: "Hello from the UI test seed recording."
                )
                self.add(seed)
            }
            return
        }
        let appSupport = try! FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true)
        let newRoot = appSupport.appendingPathComponent("Mila", isDirectory: true)
        // Migration chain: prefer the newer IslandWhisper directory over the
        // older IvritWhisper directory. Whichever exists first in this list
        // wins — we never merge them, the user's most recent app's data is
        // what they expect to see post-upgrade.
        let legacyRoots = [
            appSupport.appendingPathComponent("IslandWhisper", isDirectory: true),
            appSupport.appendingPathComponent("IvritWhisper", isDirectory: true)
        ]
        let fm = FileManager.default
        if !fm.fileExists(atPath: newRoot.path),
           let legacy = legacyRoots.first(where: { fm.fileExists(atPath: $0.path) }) {
            do {
                try fm.moveItem(at: legacy, to: newRoot)
                print("RecordingStore: migrated \(legacy.path) -> \(newRoot.path)")
            } catch {
                print("RecordingStore: migration from \(legacy.lastPathComponent) failed (\(error)) — falling back to fresh dir")
            }
        }
        self.init(rootDirectory: newRoot)
        // The user override (if any) is applied by MilaApp after the
        // store + the storage-settings instance it owns are both wired
        // up — we don't observe the bookmark from inside the store so
        // the test path (`init(rootDirectory:)`) stays cleanly isolated
        // from UserDefaults.
    }

    /// Production-style init. `rootDirectory` is where the model cache
    /// and the default recordings folder live. `customRecordingsDirectory`
    /// is the user override — when non-nil, recordings + their json
    /// sidecars live there instead of `<rootDirectory>/Recordings`.
    /// Used by tests that need to verify the relocated-at-construction
    /// path; production wires the override via `relocateRecordings(to:)`
    /// from MilaApp.
    convenience init(rootDirectory: URL, customRecordingsDirectory: URL?) {
        self.init(rootDirectory: rootDirectory)
        if let custom = customRecordingsDirectory {
            relocateRecordings(to: custom)
        }
    }

    /// Root passed into `init(rootDirectory:)`. Cached so
    /// `relocateRecordings(to: nil)` can revert to the original
    /// default-path layout (json files sit alongside the `Recordings/`
    /// subdir, matching the historical shape that pre-v1.7 builds
    /// shipped).
    private let originalRootDirectory: URL

    init(rootDirectory: URL) {
        self.originalRootDirectory = rootDirectory
        let defaultRecs = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        self.defaultRecordingsDirectory = defaultRecs
        self.recordingsDirectory = defaultRecs
        self.modelsDirectory = rootDirectory.appendingPathComponent("Models", isDirectory: true)
        self.storeURL = rootDirectory.appendingPathComponent("recordings.json")
        self.foldersURL = rootDirectory.appendingPathComponent("folders.json")

        try? fileManager.createDirectory(at: defaultRecs, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        load()
        loadFolders()
    }

    /// Switch the recordings directory to `newDirectory`. Clears the
    /// in-memory state and re-loads from the new location's
    /// `recordings.json` + `folders.json` (if any). Existing recordings
    /// at the old location stay on disk; this is intentionally a
    /// "point at the new folder" operation, not a "move my data" one
    /// — moving content is a separate action.
    ///
    /// Layout:
    ///   * Default (newDirectory == nil): json files at
    ///     `<originalRoot>/recordings.json` (sibling of the
    ///     `Recordings/` subdir), wavs inside the subdir. Matches the
    ///     historical layout.
    ///   * Custom: json files at `<newDirectory>/recordings.json`,
    ///     wavs in the same directory. Makes the chosen folder
    ///     self-contained so the user can hand it to backup software
    ///     / a cloud-sync app without picking up the model cache.
    func relocateRecordings(to newDirectory: URL?) {
        if let custom = newDirectory {
            try? fileManager.createDirectory(at: custom, withIntermediateDirectories: true)
            self.recordingsDirectory = custom
            self.storeURL = custom.appendingPathComponent("recordings.json")
            self.foldersURL = custom.appendingPathComponent("folders.json")
        } else {
            self.recordingsDirectory = defaultRecordingsDirectory
            self.storeURL = originalRootDirectory.appendingPathComponent("recordings.json")
            self.foldersURL = originalRootDirectory.appendingPathComponent("folders.json")
            try? fileManager.createDirectory(at: defaultRecordingsDirectory, withIntermediateDirectories: true)
        }
        // Reset published state before reload so subscribers don't
        // briefly see the old recordings under the new location label.
        self.recordings = []
        self.folders = []
        self.pendingRecoveryIDs = []
        load()
        loadFolders()
    }

    func audioURL(for recording: Recording) -> URL {
        recordingsDirectory.appendingPathComponent(recording.audioFileName)
    }

    /// Total bytes used by recording audio files on disk — drives the
    /// storage cap (`RecordingStorageSettings.limitBytes`). Sums the audio
    /// files of all known recordings (trashed included; they occupy disk
    /// until purged). Sidecars (.txt/.srt/.json) are negligible and
    /// omitted. Best-effort: unreadable files count as 0.
    func currentUsageBytes() -> Int64 {
        var total: Int64 = 0
        for rec in recordings {
            let url = audioURL(for: rec)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Recordings with a compression in flight — guards against two
    /// `compressRecordingAudio` runs overlapping for the same id.
    private var compressingIDs: Set<UUID> = []

    /// Transcode a recording's WAV to AAC/.m4a, point the recording at the
    /// smaller file, and delete the WAV. The audio base name is unchanged
    /// (only `.wav`→`.m4a`), so the `.txt`/`.srt`/`.summary.txt` sidecars
    /// (derived from the base) keep their names. No-op when the audio
    /// isn't a WAV (already compressed / imported m4a) or is missing.
    /// Best-effort: a failed encode leaves the WAV untouched.
    func compressRecordingAudio(id: UUID) async {
        guard let rec = recordings.first(where: { $0.id == id }) else { return }
        // Only compress finished recordings. A .pending/.running recording
        // is still being read by the transcription queue (whisper +
        // diarizer subprocess) — transcoding + deleting its WAV mid-flight
        // would break those reads.
        guard rec.status == .completed else { return }
        let src = audioURL(for: rec)
        guard src.pathExtension.lowercased() == "wav",
              FileManager.default.fileExists(atPath: src.path) else { return }
        // Prevent two compressions of the SAME recording from overlapping
        // (post-stop hook + the reclaim action, or duplicate completion
        // tasks). check+insert is synchronous on the main actor before the
        // first `await`, so it's atomic — otherwise the loser would delete
        // the winner's freshly-written .m4a in its stale-metadata branch
        // below, leaving the recording with no audio on disk.
        guard !compressingIDs.contains(id) else { return }
        compressingIDs.insert(id)
        defer { compressingIDs.remove(id) }
        let dstName = (rec.audioFileName as NSString).deletingPathExtension + ".m4a"
        let dst = recordingsDirectory.appendingPathComponent(dstName)
        do {
            try await AudioCompressor.compress(wavURL: src, toM4A: dst)
        } catch {
            recStoreLog.error("compressRecordingAudio failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: dst)  // don't leave a partial m4a
            return
        }
        // Re-fetch by id: the recording may have been edited/removed during
        // the (off-main) encode. Only swap if it's still the same WAV.
        guard let idx = recordings.firstIndex(where: { $0.id == id }),
              recordings[idx].audioFileName == rec.audioFileName else {
            try? FileManager.default.removeItem(at: dst)
            return
        }
        recordings[idx].audioFileName = dstName
        persist()
        try? FileManager.default.removeItem(at: src)
        recStoreLog.log("compressed recording \(id, privacy: .public) → \(dstName, privacy: .public)")
    }

    /// Number of finished recordings still stored as WAV (i.e. compressible).
    /// Drives the "Compress existing recordings" affordance. Pending/running
    /// recordings are excluded — their WAV is still being transcribed.
    func wavRecordingCount() -> Int {
        recordings.filter { $0.status == .completed && $0.audioFileName.lowercased().hasSuffix(".wav") }.count
    }

    /// Transcode every WAV recording to m4a — the one-time "reclaim space"
    /// action. Sequential to bound CPU/memory. `onProgress(done, total)`
    /// fires on the main actor after each. Returns the count converted.
    @discardableResult
    func compressAllWAVRecordings(onProgress: (@MainActor (Int, Int) -> Void)? = nil) async -> Int {
        let wavIDs = recordings
            .filter { $0.status == .completed && $0.audioFileName.lowercased().hasSuffix(".wav") }
            .map(\.id)
        for (i, id) in wavIDs.enumerated() {
            await compressRecordingAudio(id: id)
            onProgress?(i + 1, wavIDs.count)
        }
        return wavIDs.count
    }

    /// Path of the per-recording `.txt` transcript sidecar. The file may not
    /// exist yet (recording still pending) — callers should treat absence as
    /// empty text.
    func transcriptURL(for recording: Recording) -> URL {
        recordingsDirectory.appendingPathComponent(recording.transcriptFileName)
    }

    /// Path of the per-recording `.summary.txt` sidecar holding the
    /// LLM-generated summary. Absent on disk whenever `recording.summary`
    /// is nil/empty — `writeSummary(for:)` removes the file in that case
    /// so an old summary doesn't outlive being cleared.
    func summaryURL(for recording: Recording) -> URL {
        recordingsDirectory.appendingPathComponent(recording.summaryFileName)
    }

    /// Path of the per-recording `.srt` subtitle sidecar auto-written after
    /// transcription. May be absent (recording still pending, or it had no
    /// segments) — callers should treat absence as "nothing to remove".
    func subtitleURL(for recording: Recording) -> URL {
        recordingsDirectory.appendingPathComponent(recording.subtitleFileName)
    }

    func freshAudioURL(suggestedName: String? = nil) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffix = String(UUID().uuidString.prefix(6))
        let base = (suggestedName?.isEmpty == false ? suggestedName! : "Recording")
            + " " + stamp + "-" + suffix
        return recordingsDirectory.appendingPathComponent(base + ".wav")
    }

    func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        writeTranscript(for: recording)
        writeSummary(for: recording)
        persist()
    }

    func update(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx] = recording
        writeTranscript(for: recording)
        writeSummary(for: recording)
        persist()
    }

    /// Rename a recording's user-facing title. No-op if the trimmed title is
    /// empty (we never want a blank entry in the sidebar) or unchanged.
    func rename(_ recording: Recording, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        guard recordings[idx].title != trimmed else { return }
        recordings[idx].title = trimmed
        persist()
    }

    /// Move a recording into a folder (or unfile it with nil). Auto-creates
    /// the folder so callers can drag into a brand-new name without a
    /// separate `createFolder` round-trip. Dedup is case-insensitive — if
    /// the caller passes "work" but "Work" already exists, the recording is
    /// filed under the existing "Work" rather than spawning a duplicate.
    func assign(_ recording: Recording, toFolder folderName: String?) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        let normalized = folderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = (normalized?.isEmpty ?? true) ? nil : normalized
        let target: String? = trimmed.map { input in
            folders.first { $0.caseInsensitiveCompare(input) == .orderedSame } ?? input
        }
        recordings[idx].folder = target
        if let target, !folders.contains(target) {
            folders.append(target)
            folders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            persistFolders()
        }
        persist()
    }

    /// Persist (or clear) the `.txt` sidecar for a recording. Empty text
    /// removes the file so we never leave a stale transcript around after a
    /// re-transcription that came up silent.
    private func writeTranscript(for recording: Recording) {
        let url = transcriptURL(for: recording)
        let text = recording.fullText
        do {
            if text.isEmpty {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            print("RecordingStore: failed to write transcript \(url.lastPathComponent): \(error)")
        }
    }

    /// Persist (or clear) the `.summary.txt` sidecar holding the LLM
    /// summary. Mirrors `writeTranscript` — an empty/cleared summary
    /// removes the file so a recording whose summary the user wiped (or
    /// that the LLM regenerated as empty) doesn't keep showing the old
    /// text in finder / external tools. `summary` lives in
    /// `recordings.json` too, so the sidecar is an extra surface, not
    /// the source of truth.
    private func writeSummary(for recording: Recording) {
        let url = summaryURL(for: recording)
        let text = (recording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if text.isEmpty {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            print("RecordingStore: failed to write summary \(url.lastPathComponent): \(error)")
        }
    }

    /// Move to "Recently Deleted". The audio file stays on disk until permanent delete.
    func softDelete(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx].deletedAt = Date()
        persist()
    }

    /// Restore from "Recently Deleted".
    func restore(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx].deletedAt = nil
        persist()
    }

    /// Remove the metadata + every on-disk file for a recording: the audio
    /// plus all sidecars (`.txt` transcript, `.summary.txt`, `.srt`
    /// subtitles). Missing files are ignored — each is best-effort so one
    /// absent sidecar doesn't strand the others.
    func permanentlyDelete(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        try? fileManager.removeItem(at: audioURL(for: recording))
        try? fileManager.removeItem(at: transcriptURL(for: recording))
        try? fileManager.removeItem(at: summaryURL(for: recording))
        try? fileManager.removeItem(at: subtitleURL(for: recording))
        persist()
    }

    /// Backwards-compatible delete: soft-delete first, permanent if already trashed.
    func delete(_ recording: Recording) {
        if recording.isTrashed {
            permanentlyDelete(recording)
        } else {
            softDelete(recording)
        }
    }

    func recordings(in category: HistoryCategory) -> [Recording] {
        switch category {
        case .recentlyDeleted:
            return recordings.filter { $0.isTrashed }
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        case .meetings:
            return recordings.filter { !$0.isTrashed && $0.source == .meeting }
        case .dictations:
            return recordings.filter { !$0.isTrashed && $0.source == .microphone && $0.title.hasPrefix("Dictation") }
        case .transcriptions:
            return recordings.filter { !$0.isTrashed }
        }
    }

    /// All non-trashed recordings filed under `folderName`.
    func recordings(inFolder folderName: String) -> [Recording] {
        recordings.filter { !$0.isTrashed && $0.folder == folderName }
    }

    /// Non-trashed recordings that haven't been filed anywhere yet. These
    /// surface in the sidebar's "Default" view. Replaces the old
    /// Transcriptions/Meetings/Dictations category split — we now have one
    /// catch-all bucket and named folders, period.
    func unfiledRecordings() -> [Recording] {
        recordings.filter { !$0.isTrashed && $0.folder == nil }
    }

    // MARK: - Folders

    /// Create an empty folder. No-op if the trimmed name is empty or already
    /// exists. Returns the normalized name that ended up in `folders` (or nil
    /// if the input was rejected) so callers can immediately select it.
    @discardableResult
    func createFolder(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if folders.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return folders.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
        folders.append(trimmed)
        folders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persistFolders()
        return trimmed
    }

    /// Rename a folder and re-tag every recording filed under it. Returns
    /// the normalized new name on success, nil if the rename was rejected
    /// (blank name, source missing, or collision with an existing folder).
    @discardableResult
    func renameFolder(_ oldName: String, to newName: String) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, folders.contains(oldName) else { return nil }
        if trimmed == oldName { return oldName }
        // Collision check must exclude the folder we're renaming — otherwise
        // a case-only rewrite ("work" -> "Work") falsely collides with itself.
        if folders.contains(where: {
            $0 != oldName && $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return nil
        }
        folders.removeAll { $0 == oldName }
        folders.append(trimmed)
        folders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for i in recordings.indices where recordings[i].folder == oldName {
            recordings[i].folder = trimmed
        }
        persistFolders()
        persist()
        return trimmed
    }

    /// Delete a folder. Recordings filed under it become unfiled (folder = nil).
    func deleteFolder(_ name: String) {
        guard folders.contains(name) else { return }
        folders.removeAll { $0 == name }
        for i in recordings.indices where recordings[i].folder == name {
            recordings[i].folder = nil
        }
        persistFolders()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode([Recording].self, from: data) else { return }

        // Hydrate fullText from the sidecar `.txt`. For records persisted
        // under the old "fullText inline" schema, the legacy decoder filled
        // it in already — we migrate those to a sidecar on first sight so
        // future writes are consistent.
        var needsMigration = false
        for i in decoded.indices {
            let url = transcriptURL(for: decoded[i])
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                decoded[i].fullText = text
            } else if !decoded[i].fullText.isEmpty {
                // Legacy record with inline text — keep what we decoded and
                // flush a sidecar so subsequent loads pick it up from disk.
                writeTranscript(for: decoded[i])
                needsMigration = true
            } else if !decoded[i].segments.isEmpty {
                // Fallback: reconstruct from segments (shouldn't normally
                // happen — segments + empty fullText only existed on the
                // brief window where status was running and we hadn't
                // flushed the final text yet).
                let joined = decoded[i].segments.map(\.text).joined()
                decoded[i].fullText = joined
            }
        }
        self.recordings = decoded.sorted { $0.createdAt > $1.createdAt }
        let recovered = recoverOrphanRecordings()
        if needsMigration || !recovered.isEmpty {
            persist()  // re-write JSON without inline fullText / with recovered entries
        }
    }

    /// IDs of recordings that were re-created from orphan .wav files at
    /// launch — i.e. the app crashed (or was force-quit) mid-recording so
    /// the audio file exists on disk but never made it into recordings.json.
    /// `MilaApp` consumes this list once after init to auto-enqueue them
    /// for transcription, then clears it.
    private(set) var pendingRecoveryIDs: [UUID] = []

    func consumePendingRecoveryIDs() -> [UUID] {
        let ids = pendingRecoveryIDs
        pendingRecoveryIDs = []
        return ids
    }

    /// Crash recovery: scan the recordings directory for `.wav` files that
    /// no Recording in the store points at. Each orphan was a recording in
    /// progress when the app died — the audio is on disk (AVAudioFile
    /// writes WAV frames incrementally), the metadata was never persisted.
    /// Re-attach those files with `.pending` status so the user sees them
    /// in the list and so the launch-time recovery sweep can enqueue them
    /// for transcription. Returns the list of newly-added recordings so
    /// the caller can decide whether to re-persist.
    @discardableResult
    private func recoverOrphanRecordings() -> [Recording] {
        let referenced = Set(recordings.map { $0.audioFileName })
        guard let entries = try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var added: [Recording] = []
        for url in entries where url.pathExtension.lowercased() == "wav" {
            let name = url.lastPathComponent
            if referenced.contains(name) { continue }
            // Skip empty files — AVAudioFile creates the WAV header on
            // open but a 44-byte placeholder isn't worth recovering.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size < 512 { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let recovered = Recording(
                title: recoveryTitle(at: mtime),
                createdAt: mtime,
                duration: 0,  // filled in by the transcription path
                source: .microphone,  // best guess; the original source isn't recoverable
                audioFileName: name,
                status: .pending
            )
            recordings.insert(recovered, at: 0)
            added.append(recovered)
            pendingRecoveryIDs.append(recovered.id)
            print("RecordingStore: recovered orphan recording \(name) (\(size) bytes)")
        }
        if !added.isEmpty {
            recordings.sort { $0.createdAt > $1.createdAt }
        }
        return added
    }

    private func recoveryTitle(at date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Recovered recording · \(f.string(from: date))"
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(recordings)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            print("RecordingStore persist error: \(error)")
        }
    }

    private func loadFolders() {
        // Folders stored as a plain JSON array of strings. Seed the union of
        // (persisted list, any folder names already referenced by recordings)
        // so we never lose a folder even if folders.json wasn't written yet
        // — e.g. tests that build a Recording with `folder: "Work"` directly.
        var union = Set<String>()
        if let data = try? Data(contentsOf: foldersURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            union.formUnion(decoded)
        }
        for r in recordings {
            if let f = r.folder, !f.isEmpty { union.insert(f) }
        }
        self.folders = union.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func persistFolders() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(folders)
            try data.write(to: foldersURL, options: .atomic)
        } catch {
            print("RecordingStore persistFolders error: \(error)")
        }
    }
}
