import Foundation
import AVFoundation
import TranscriptionCore
@testable import Mila

/// Shared helpers for the test bundle.
enum TestSupport {

    /// Make a fresh temp directory rooted under the system temp dir.
    /// Caller is responsible for cleaning up.
    static func makeTempRoot(label: String = "MilaTests") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID())", isDirectory: true)
    }

    /// Write a 1-second 16kHz mono Float32 WAV containing a simple sine wave.
    /// Returns the URL the file was written to.
    @discardableResult
    static func writeSineWav(at url: URL,
                             durationSeconds: Double = 1.0,
                             frequencyHz: Double = 440,
                             amplitude: Float = 0.3) throws -> URL {
        let format = WhisperAudioFormat.pcmFloat32
        let frames = AVAudioFrameCount(format.sampleRate * durationSeconds)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try {
            let file = try AVAudioFile(forWriting: url,
                                       settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: frames) else {
                throw NSError(domain: "TestSupport", code: 1)
            }
            buffer.frameLength = frames
            if let ptr = buffer.floatChannelData?[0] {
                let twoPi = 2.0 * Double.pi
                for i in 0..<Int(frames) {
                    let phase = twoPi * frequencyHz * Double(i) / format.sampleRate
                    ptr[i] = Float(sin(phase)) * amplitude
                }
            }
            try file.write(from: buffer)
        }()
        return url
    }

    /// Write a stereo 48kHz Float32 WAV with the same sine wave on both channels.
    /// Useful for exercising downmix/resample paths.
    @discardableResult
    static func writeStereo48kSineWav(at url: URL,
                                      durationSeconds: Double = 1.0,
                                      frequencyHz: Double = 220,
                                      amplitude: Float = 0.4) throws -> URL {
        guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000,
                                               channels: 2,
                                               interleaved: false) else {
            throw NSError(domain: "TestSupport", code: 2)
        }
        let frames = AVAudioFrameCount(48_000 * durationSeconds)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try {
            let file = try AVAudioFile(forWriting: url,
                                       settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat,
                                                frameCapacity: frames) else {
                throw NSError(domain: "TestSupport", code: 3)
            }
            buffer.frameLength = frames
            let twoPi = 2.0 * Double.pi
            for ch in 0..<2 {
                guard let ptr = buffer.floatChannelData?[ch] else { continue }
                for i in 0..<Int(frames) {
                    let phase = twoPi * frequencyHz * Double(i) / 48_000.0
                    ptr[i] = Float(sin(phase)) * amplitude
                }
            }
            try file.write(from: buffer)
        }()
        return url
    }

    /// Write a fake "model" file so `ModelManager.isInstalled(.ivritLarge)` returns true.
    /// The file is intentionally garbage — only `WhisperEngine` would care, and
    /// tests use `StubWhisperEngine`.
    @MainActor
    static func installFakeModel(into manager: ModelManager,
                                 model: WhisperModel = .ivritLarge) throws {
        manager.setSelected(model)
        let url = manager.url(for: model)
        try Data("not-a-real-model-just-for-tests".utf8).write(to: url)
        manager.refreshInstalled()
    }

    /// A `RemoteTranscriptionSettings` isolated to a fresh per-`label`
    /// UserDefaults suite, defaulting to the LOCAL backend.
    ///
    /// Any `TranscriptionService` test that injects a `StubWhisperEngine`
    /// MUST also pass one of these as `remoteSettings:`. Otherwise the service
    /// falls back to `RemoteTranscriptionSettings()` which reads `.standard`
    /// UserDefaults — and on a machine where `transcription.backend = remote`
    /// is persisted there (a dev box that ran Live AI, or a leaked test write),
    /// the service routes to the REAL remote endpoint and bypasses the stub
    /// entirely, reddening the whole suite with real transcripts. Isolating to
    /// a clean suite (which has no `transcription.backend` key, so it defaults
    /// to `.local`) makes the stub authoritative regardless of host state.
    @MainActor
    static func isolatedRemoteSettings(label: String) -> RemoteTranscriptionSettings {
        let suiteName = "\(label).remote"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return RemoteTranscriptionSettings(defaults: suite)
    }
}

/// A `Recording` constructed for tests, paired with its on-disk audio file.
@MainActor
struct TestRecordingFixture {
    let recording: Recording
    let audioURL: URL

    static func make(in store: RecordingStore,
                     title: String = "Test Recording",
                     durationSeconds: Double = 0.5,
                     source: RecordingSource = .microphone,
                     language: String = "he") throws -> TestRecordingFixture {
        let audioURL = store.freshAudioURL(suggestedName: title)
        try TestSupport.writeSineWav(at: audioURL, durationSeconds: durationSeconds)
        let recording = Recording(
            title: title,
            duration: durationSeconds,
            source: source,
            audioFileName: audioURL.lastPathComponent,
            language: language
        )
        store.add(recording)
        return TestRecordingFixture(recording: recording, audioURL: audioURL)
    }
}
