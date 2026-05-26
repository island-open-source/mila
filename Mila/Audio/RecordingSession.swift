import Foundation
import AVFoundation
import Combine
import OSLog
import ScreenCaptureKit
import TranscriptionCore

private let recLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "RecordingSession")

/// Orchestrates microphone + system audio capture into a single mono 16kHz WAV file.
@MainActor
final class RecordingSession: ObservableObject {
    enum State { case idle, recording, stopping }
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0

    let mic = MicrophoneRecorder()
    let system = SystemAudioRecorder()

    private(set) var source: RecordingSource = .microphone
    /// Path of the WAV currently being written. `nil` while idle. The live
    /// streaming consumers (LiveSpeakerDiarizer) read partial frames out of
    /// this file while we're still appending to it — safe because
    /// `AVAudioFile` writes the WAV header on construction and frames are
    /// appended without rewriting earlier bytes.
    private(set) var fileURL: URL?
    private var audioFile: AVAudioFile?
    private var startTime: Date?
    private var timerTask: Task<Void, Never>?
    private var micTask: Task<Void, Never>?
    private var systemTask: Task<Void, Never>?

    /// Latest sample buffers, used by the mixer to combine mic + system per chunk.
    private var pendingMic: [Float] = []
    private var pendingSystem: [Float] = []
    private let writeQueue = DispatchQueue(label: "io.island.mila.recording-write")

    /// Fired with each post-mix sample chunk so the live transcriber
    /// (and any other realtime consumer) can stream during recording.
    /// We deliberately don't also retain a full-recording PCM buffer
    /// here — `LiveTranscriber` keeps its own rolling window, and the
    /// authoritative on-disk copy is the WAV we write per-chunk via
    /// `writer`. (Earlier versions kept a duplicate `liveSamples`
    /// array that was never read; removed in PR #20 after Bugbot
    /// flagged the second full-length in-memory copy.)
    var onLiveSamples: ((ArraySlice<Float>) -> Void)?

    func refreshSystemAudioApps() async {
        await system.refreshShareableContent()
    }

    func selectApp(_ app: SCRunningApplication?) {
        system.selectedApp = app
    }

    func start(source: RecordingSource, outputURL: URL) async throws {
        guard state == .idle else { return }
        self.source = source
        self.fileURL = outputURL
        self.writesSinceStart = 0

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
        self.audioFile = try AVAudioFile(forWriting: outputURL, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)

        if source == .microphone || source == .meeting {
            _ = await mic.requestAccess()
            try await mic.start()
            micTask = Task { [weak self] in
                guard let self else { return }
                for await buf in self.mic.audioStream {
                    await self.consumeMic(buf)
                }
            }
        }

        if source == .systemAudio || source == .meeting {
            try await system.start()
            systemTask = Task { [weak self] in
                guard let self else { return }
                for await buf in self.system.audioStream {
                    await self.consumeSystem(buf)
                }
            }
        }

        startTime = Date()
        state = .recording
        timerTask = Task { @MainActor [weak self] in
            while let self, self.state == .recording {
                if let start = self.startTime {
                    self.elapsed = Date().timeIntervalSince(start)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func stop() async -> URL? {
        guard state == .recording else { return fileURL }
        state = .stopping
        await mic.stop()
        await system.stop()
        micTask?.cancel(); micTask = nil
        systemTask?.cancel(); systemTask = nil
        timerTask?.cancel(); timerTask = nil

        await flushPending(force: true)
        let url = fileURL
        audioFile = nil
        fileURL = nil
        startTime = nil
        elapsed = 0
        state = .idle
        return url
    }

    /// Tear down any active capture without trying to flush a final WAV.
    /// Used by the AppDelegate at terminate time so we hand the user's mic
    /// and screen-recording grants back to macOS instead of leaving them
    /// pinned by a half-running session.
    func cancelAll() async {
        guard state != .idle else { return }
        await mic.stop()
        await system.stop()
        micTask?.cancel(); micTask = nil
        systemTask?.cancel(); systemTask = nil
        timerTask?.cancel(); timerTask = nil
        audioFile = nil
        fileURL = nil
        startTime = nil
        elapsed = 0
        pendingMic.removeAll(keepingCapacity: false)
        pendingSystem.removeAll(keepingCapacity: false)
        state = .idle
    }

    // MARK: - Mixing

    private func consumeMic(_ buffer: AVAudioPCMBuffer) async {
        let samples = AudioConvert.samples(from: buffer)
        await MainActor.run { self.micLevel = AudioMeter.level(from: buffer) }
        if source == .microphone {
            await write(samples)
        } else {
            pendingMic.append(contentsOf: samples)
            await flushPending(force: false)
        }
    }

    private func consumeSystem(_ buffer: AVAudioPCMBuffer) async {
        let samples = AudioConvert.samples(from: buffer)
        await MainActor.run { self.systemLevel = AudioMeter.level(from: buffer) }
        if source == .systemAudio {
            await write(samples)
        } else {
            pendingSystem.append(contentsOf: samples)
            await flushPending(force: false)
        }
    }

    /// When recording mic+system, emit pairs of equal length, average them, and write.
    private func flushPending(force: Bool) async {
        let count = min(pendingMic.count, pendingSystem.count)
        guard count > 0 else {
            if force {
                let leftover: [Float]
                if pendingMic.count > pendingSystem.count {
                    leftover = pendingMic
                    pendingMic.removeAll()
                } else {
                    leftover = pendingSystem
                    pendingSystem.removeAll()
                }
                if !leftover.isEmpty { await write(leftover) }
            }
            return
        }
        var mixed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            mixed[i] = (pendingMic[i] + pendingSystem[i]) * 0.5
        }
        pendingMic.removeFirst(count)
        pendingSystem.removeFirst(count)
        await write(mixed)
    }

    private var writesSinceStart: Int = 0

    private func write(_ samples: [Float]) async {
        guard let file = audioFile, !samples.isEmpty else { return }
        writesSinceStart += 1
        if writesSinceStart <= 3 || writesSinceStart % 50 == 0 {
            let hasOnLive = onLiveSamples != nil
            recLog.log("write #\(self.writesSinceStart) samples=\(samples.count) hasOnLiveCb=\(hasOnLive, privacy: .public)")
        }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        do {
            try file.write(from: buffer)
        } catch {
            print("Audio file write error: \(error)")
        }
        if let onLive = onLiveSamples {
            onLive(samples[0..<samples.count])
        }
    }
}
