import Foundation
import AVFoundation
import OSLog

private let compressorLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "AudioCompressor")

/// Transcodes recordings from the on-disk WAV (written live during a
/// session — crash-recoverable, which the launch recovery relies on) to
/// AAC/`.m4a` for ~10× smaller storage. AAC is the macOS-native
/// compressed format (hardware-accelerated, far better than mp3 — which
/// AVFoundation can't even encode). The recordings are 16 kHz mono
/// speech, so 32 kbps AAC is plenty (~14 MB/hour vs ~230 MB/hour WAV).
///
/// Transcription (AVFoundation) and playback (AVPlayer) read m4a natively;
/// only the Python diarizer's `soundfile` backend can't, so
/// `decodeToTempWAV` feeds it a plain WAV when needed.
enum AudioCompressor {
    enum CompressError: Error { case makeBuffer }

    /// Read `wavURL` and write an AAC `.m4a` to `destURL` (overwriting any
    /// existing file there). Runs the encode off the main actor.
    static func compress(wavURL: URL, toM4A destURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let input = try AVAudioFile(forReading: wavURL)
            let inFormat = input.processingFormat
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inFormat.sampleRate,
                AVNumberOfChannelsKey: inFormat.channelCount,
                AVEncoderBitRateKey: 32_000
            ]
            if FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.removeItem(at: destURL)
            }
            let output = try AVAudioFile(forWriting: destURL, settings: settings)
            let chunk: AVAudioFrameCount = 1 << 16
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else {
                throw CompressError.makeBuffer
            }
            // Bound the loop by frame position — AVAudioFile.read throws a
            // generic nilError on a read attempted PAST end-of-file, so we
            // must never call it once we've consumed all frames.
            let totalFrames = input.length
            while input.framePosition < totalFrames {
                let remaining = AVAudioFrameCount(totalFrames - input.framePosition)
                try input.read(into: buffer, frameCount: min(chunk, remaining))
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            compressorLog.log("compressed \(wavURL.lastPathComponent, privacy: .public) → \(destURL.lastPathComponent, privacy: .public)")
        }.value
    }

    /// Decode any AVFoundation-readable file (m4a, wav, …) into a fresh
    /// 16 kHz mono float32 WAV in the temp dir, so the Python diarizer's
    /// `soundfile`/libsndfile backend (which can't read m4a) gets a plain
    /// WAV. Caller owns the returned temp file and should delete it.
    static func decodeToTempWAV(_ url: URL) throws -> URL {
        let samples = try AudioConvert.loadAsWhisperSamples(url: url)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-diar-\(UUID().uuidString).wav")
        try AudioConvert.writeWhisperWAV(samples: samples, to: temp)
        return temp
    }
}
