import Foundation
import TranscriptionCore

enum RecordingSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case meeting
    /// Imported from the iPhone's Voice Memos app via the iCloud-synced
    /// folder on this Mac. Distinct from Mila's own mic capture (which is
    /// `.microphone`) so the origin is visible in the UI and so the sync
    /// importer can dedup these against `Recording.voiceMemoUniqueID`.
    case voiceMemo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System audio"
        case .meeting: return "Meeting (mic + system)"
        case .voiceMemo: return "Voice Memo"
        }
    }

    var sfSymbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.3.fill"
        case .meeting: return "person.2.wave.2.fill"
        case .voiceMemo: return "waveform"
        }
    }
}

enum TranscriptionStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
}

struct Recording: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var source: RecordingSource
    /// File name (relative to recordings directory) of the .wav file.
    var audioFileName: String
    var status: TranscriptionStatus
    var language: String
    var modelName: String?
    var segments: [TranscriptSegment]
    /// Plain-text transcript. Persisted to a sidecar `.txt` file on disk
    /// (RecordingStore handles I/O); NOT encoded into recordings.json so the
    /// metadata blob stays small as the user accumulates recordings.
    var fullText: String
    /// When non-nil the recording is in the "Recently Deleted" trash.
    var deletedAt: Date?
    /// User-assigned folder. nil = unfiled. Flat namespace (no nesting).
    var folder: String?
    /// The captured app's name when the recording came from an app-audio
    /// (or meeting) capture — used to surface a Zoom-specific badge for
    /// Zoom recordings without re-deriving from the title. nil for
    /// microphone-only or system-wide system-audio captures.
    var appName: String?

    /// Rolling Live-AI summary captured at the moment recording stopped.
    /// nil for any recording that ran without Live AI mode active.
    var summary: String?

    /// Action items surfaced by Live AI during the recording. nil when
    /// Live AI wasn't running; an empty array means it ran but produced
    /// nothing (rare — usually means the LLM CLI returned an error).
    var actionItems: [ActionItem]?

    /// Stable per-recording identifier from the iPhone Voice Memos library
    /// (`ZCLOUDRECORDING.ZUNIQUEID`) when `source == .voiceMemo`. The sync
    /// importer keys on this to skip recordings it already imported, so a
    /// rescan or app restart never re-imports the same memo. nil for every
    /// non-Voice-Memo recording.
    var voiceMemoUniqueID: String?

    init(id: UUID = UUID(),
         title: String,
         createdAt: Date = Date(),
         duration: Double = 0,
         source: RecordingSource,
         audioFileName: String,
         status: TranscriptionStatus = .pending,
         language: String = "he",
         modelName: String? = nil,
         segments: [TranscriptSegment] = [],
         fullText: String = "",
         deletedAt: Date? = nil,
         folder: String? = nil,
         appName: String? = nil,
         summary: String? = nil,
         actionItems: [ActionItem]? = nil,
         voiceMemoUniqueID: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
        self.audioFileName = audioFileName
        self.status = status
        self.language = language
        self.modelName = modelName
        self.segments = segments
        self.fullText = fullText
        self.deletedAt = deletedAt
        self.folder = folder
        self.appName = appName
        self.summary = summary
        self.actionItems = actionItems
        self.voiceMemoUniqueID = voiceMemoUniqueID
    }

    var isTrashed: Bool { deletedAt != nil }

    /// File name (relative to recordings directory) of the sidecar `.txt`
    /// holding the plain-text transcript. Derived from `audioFileName` so a
    /// recording + its transcript stay side by side and survive a rename.
    var transcriptFileName: String {
        (audioFileName as NSString).deletingPathExtension + ".txt"
    }

    /// File name (relative to recordings directory) of the sidecar
    /// `.summary.txt` holding the LLM-generated meeting summary. Same
    /// derive-from-audio convention as `transcriptFileName` so a user
    /// browsing the recordings directory sees `Foo.wav` + `Foo.txt` +
    /// `Foo.summary.txt` clustered together. Absent on disk whenever
    /// `summary` is nil/empty — the store deletes the sidecar in that
    /// case so we never leave a stale summary around.
    var summaryFileName: String {
        (audioFileName as NSString).deletingPathExtension + ".summary.txt"
    }

    /// File name (relative to recordings directory) of the sidecar `.srt`
    /// subtitle file auto-written after transcription (see
    /// `TranscriptExporter.writeSRT(for:in:)`). Same derive-from-audio
    /// convention as the other sidecars so deleting a recording can clean
    /// up `Foo.srt` alongside `Foo.wav`/`Foo.txt`/`Foo.summary.txt`.
    var subtitleFileName: String {
        (audioFileName as NSString).deletingPathExtension + ".srt"
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, source, audioFileName,
             status, language, modelName, segments, deletedAt, folder, appName,
             summary, actionItems, voiceMemoUniqueID
        // `fullText` deliberately excluded — lives in a sidecar .txt file.
        // Legacy records that had it inline are decoded via the custom init.
        case fullText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.duration = try c.decode(Double.self, forKey: .duration)
        self.source = try c.decode(RecordingSource.self, forKey: .source)
        self.audioFileName = try c.decode(String.self, forKey: .audioFileName)
        self.status = try c.decode(TranscriptionStatus.self, forKey: .status)
        self.language = try c.decode(String.self, forKey: .language)
        self.modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
        self.segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.folder = try c.decodeIfPresent(String.self, forKey: .folder)
        self.appName = try c.decodeIfPresent(String.self, forKey: .appName)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems)
        self.voiceMemoUniqueID = try c.decodeIfPresent(String.self, forKey: .voiceMemoUniqueID)
        // Legacy records still have fullText inline; new records leave it
        // empty here and RecordingStore loads it from the sidecar .txt.
        self.fullText = try c.decodeIfPresent(String.self, forKey: .fullText) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(duration, forKey: .duration)
        try c.encode(source, forKey: .source)
        try c.encode(audioFileName, forKey: .audioFileName)
        try c.encode(status, forKey: .status)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(modelName, forKey: .modelName)
        try c.encode(segments, forKey: .segments)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(actionItems, forKey: .actionItems)
        try c.encodeIfPresent(voiceMemoUniqueID, forKey: .voiceMemoUniqueID)
        // fullText intentionally omitted — sidecar .txt is the source of truth.
    }

    /// True when the captured app appears to be Zoom (zoom.us / Zoom).
    /// Used by list rows to surface a Zoom-specific badge. Falls back to a
    /// title-substring check so app-audio recordings imported before we
    /// started persisting `appName` still get the badge.
    var isZoomRecording: Bool {
        if let name = appName?.lowercased(), name.contains("zoom") {
            return true
        }
        return title.lowercased().contains("zoom")
    }
}

/// Categories used by the sidebar.
enum HistoryCategory: String, CaseIterable, Identifiable, Hashable {
    case transcriptions   // any non-deleted recording with a transcript
    case meetings         // source == .meeting
    case dictations       // source == .microphone, marked as dictation
    case recentlyDeleted

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .transcriptions:   return "Transcriptions"
        case .meetings:         return "Meetings"
        case .dictations:       return "Dictations"
        case .recentlyDeleted:  return "Recently Deleted"
        }
    }
    var sfSymbol: String {
        switch self {
        case .transcriptions:   return "text.alignleft"
        case .meetings:         return "person.2.wave.2"
        case .dictations:       return "mic"
        case .recentlyDeleted:  return "trash"
        }
    }
}
