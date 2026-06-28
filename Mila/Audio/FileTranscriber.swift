import Foundation
import AVFoundation
import TranscriptionCore

/// Imports an arbitrary audio / video file (m4a, mp3, mp4, wav, mov, …),
/// re-encodes it to whisper-format mono 16 kHz Float32 WAV inside the
/// recordings directory, and returns a Recording stub ready for transcription.
@MainActor
enum FileTranscriber {

    static func importFile(at sourceURL: URL,
                           into store: RecordingStore,
                           language: RecordingLanguage = .hebrew,
                           source: RecordingSource = .systemAudio,
                           title titleOverride: String? = nil,
                           createdAt: Date? = nil,
                           voiceMemoUniqueID: String? = nil) async throws -> Recording {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

        let title = titleOverride ?? sourceURL.deletingPathExtension().lastPathComponent
        // `freshAudioURL` appends the suggested name as a path component, so a
        // title containing "/" (or ":", which Finder maps to "/") would create
        // nested/invalid paths. Sanitize the stem used for the audio file;
        // the recording keeps the original `title` for display.
        let safeStem = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let destURL = store.freshAudioURL(suggestedName: safeStem)

        let duration = try await reencode(source: sourceURL, destination: destURL)

        let recording = Recording(
            title: title,
            createdAt: createdAt ?? Date(),
            duration: duration,
            source: source,
            audioFileName: destURL.lastPathComponent,
            language: language.rawValue,
            voiceMemoUniqueID: voiceMemoUniqueID
        )
        store.add(recording)
        return recording
    }

    /// Read the source file using AVAudioFile and write a Whisper-format WAV.
    /// AVAudioFile transparently uses ExtAudioFile under the hood, so it can
    /// open any format the system can decode (m4a, mp3, AAC inside mp4, etc).
    private static func reencode(source: URL, destination: URL) async throws -> Double {
        try await Task.detached(priority: .userInitiated) {
            let inFile = try AVAudioFile(forReading: source)
            let format = WhisperAudioFormat.pcmFloat32

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let outFile = try AVAudioFile(forWriting: destination,
                                          settings: settings,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false)

            let chunk: AVAudioFrameCount = 32_768
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat,
                                                     frameCapacity: chunk) else {
                throw NSError(domain: "FileTranscriber", code: 1)
            }

            var totalFramesIn: AVAudioFramePosition = 0
            while inFile.framePosition < inFile.length {
                let toRead = min(chunk, AVAudioFrameCount(inFile.length - inFile.framePosition))
                inputBuffer.frameLength = toRead
                try inFile.read(into: inputBuffer, frameCount: toRead)
                let converted = try AudioConvert.toWhisperFormat(inputBuffer)
                try outFile.write(from: converted)
                totalFramesIn += AVAudioFramePosition(toRead)
            }
            return Double(totalFramesIn) / inFile.processingFormat.sampleRate
        }.value
    }

    /// File extensions accepted by the Open Files panel.
    static let allowedExtensions: [String] = [
        "wav", "aif", "aiff", "caf",
        "m4a", "mp3", "aac",
        "mp4", "mov", "m4v", "mkv",
        "webm", "ogg", "flac"
    ]
}
