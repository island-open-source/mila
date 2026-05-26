import Foundation
import Combine

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
    private let storeURL: URL
    private let foldersURL: URL
    let recordingsDirectory: URL
    let modelsDirectory: URL

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
    }

    init(rootDirectory: URL) {
        self.recordingsDirectory = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        self.modelsDirectory = rootDirectory.appendingPathComponent("Models", isDirectory: true)
        self.storeURL = rootDirectory.appendingPathComponent("recordings.json")
        self.foldersURL = rootDirectory.appendingPathComponent("folders.json")

        try? fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        load()
        loadFolders()
    }

    func audioURL(for recording: Recording) -> URL {
        recordingsDirectory.appendingPathComponent(recording.audioFileName)
    }

    /// Path of the per-recording `.txt` transcript sidecar. The file may not
    /// exist yet (recording still pending) — callers should treat absence as
    /// empty text.
    func transcriptURL(for recording: Recording) -> URL {
        recordingsDirectory.appendingPathComponent(recording.transcriptFileName)
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
        persist()
    }

    func update(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx] = recording
        writeTranscript(for: recording)
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

    /// Remove the metadata + audio file from disk.
    func permanentlyDelete(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        try? fileManager.removeItem(at: audioURL(for: recording))
        try? fileManager.removeItem(at: transcriptURL(for: recording))
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
