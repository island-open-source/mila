import Foundation

enum RecordingSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case meeting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System audio"
        case .meeting: return "Meeting (mic + system)"
        }
    }

    var sfSymbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.3.fill"
        case .meeting: return "person.2.wave.2.fill"
        }
    }
}

enum TranscriptionStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
}

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
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
         deletedAt: Date? = nil) {
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
    }

    var isTrashed: Bool { deletedAt != nil }

    /// File name (relative to recordings directory) of the sidecar `.txt`
    /// holding the plain-text transcript. Derived from `audioFileName` so a
    /// recording + its transcript stay side by side and survive a rename.
    var transcriptFileName: String {
        (audioFileName as NSString).deletingPathExtension + ".txt"
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, source, audioFileName,
             status, language, modelName, segments, deletedAt
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
        // fullText intentionally omitted — sidecar .txt is the source of truth.
    }
}

/// Categories used by the sidebar. Matches the History grouping.
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
