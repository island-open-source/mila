import Foundation
import Combine

/// Persists recordings + their metadata under Application Support/IslandWhisper.
///
/// The pre-rename location was `Application Support/IvritWhisper`; we
/// transparently migrate that on first launch so users don't lose their
/// already-downloaded models (~1.6 GB) or recordings.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    private let fileManager = FileManager.default
    private let storeURL: URL
    let recordingsDirectory: URL
    let modelsDirectory: URL

    convenience init() {
        let appSupport = try! FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true)
        let newRoot = appSupport.appendingPathComponent("IslandWhisper", isDirectory: true)
        let oldRoot = appSupport.appendingPathComponent("IvritWhisper", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: newRoot.path),
           fm.fileExists(atPath: oldRoot.path) {
            do {
                try fm.moveItem(at: oldRoot, to: newRoot)
                print("RecordingStore: migrated \(oldRoot.path) -> \(newRoot.path)")
            } catch {
                print("RecordingStore: migration from IvritWhisper failed (\(error)) — falling back to fresh dir")
            }
        }
        self.init(rootDirectory: newRoot)
    }

    init(rootDirectory: URL) {
        self.recordingsDirectory = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        self.modelsDirectory = rootDirectory.appendingPathComponent("Models", isDirectory: true)
        self.storeURL = rootDirectory.appendingPathComponent("recordings.json")

        try? fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        load()
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
        if needsMigration {
            persist()  // re-write JSON without inline fullText
        }
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
}
