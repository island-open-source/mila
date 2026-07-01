import Foundation
import AVFoundation
import Combine
import OSLog
import ScreenCaptureKit
import TranscriptionCore

private let recLog = MilaLog(category: "RecordingSession")

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
    /// Mic frames captured by the most recent recording, snapshotted at
    /// `stop()` before the engine is torn down. 0 for a mic/meeting recording
    /// means the microphone produced nothing — read by the caller to surface
    /// an actionable message instead of a silent "failed" recording.
    private(set) var lastMicFrameCount: Int = 0
    /// True only for a UI-test session started via `startFakeForTesting`.
    /// Read by `stop()` so it doesn't snapshot a 0 mic-frame count (the fake
    /// session never starts the real mic) — otherwise `stopRecording` would
    /// trip its empty-mic `lastError` alert and pop a blocking modal over
    /// the UI test.
    private var isFakeForTesting = false
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

    /// Jitter buffer for system audio in meeting mode. The mic is the
    /// master clock (it delivers continuously at 16kHz); each mic chunk in
    /// `consumeMic` pulls an equal span of system audio out of here and
    /// mixes the two. ScreenCaptureKit only delivers system buffers while
    /// sound is actually playing, so this drains to empty during quiet
    /// stretches — the mix just falls back to mic-only for that span, which
    /// is why the live feed never starves the way the old mic/system
    /// pairing did.
    private var pendingSystem: [Float] = []
    /// Cap on the system jitter buffer (~30s @ 16kHz). Generous so normal SCK
    /// bursts / clock skew just *delay* app audio (the mic clock catches back
    /// up) instead of losing it; only a genuinely stuck mic clock reaches the
    /// cap, and `consumeSystem` logs when it trims so the loss isn't silent.
    private let maxPendingSystem = Int(WhisperAudioFormat.sampleRate) * 30
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
        self.isFakeForTesting = false

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

    /// UI-test seam: flip state to .recording without spinning up
    /// AVAudioEngine. The caller (a launch-arg-driven injection task
    /// in `MilaApp.init`) is responsible for pushing samples into
    /// `onLiveSamples` to drive the rest of the pipeline. Avoids
    /// depending on a real microphone (or a CI-flaky virtual loopback
    /// like BlackHole) for the audio-capture E2E.
    ///
    /// Stop is the same as the real flow: caller invokes `stop()` and
    /// gets back the (possibly nil) outputURL.
    func startFakeForTesting(outputURL: URL) async {
        guard state == .idle else { return }
        self.source = .microphone
        self.fileURL = outputURL
        self.writesSinceStart = 0
        self.isFakeForTesting = true
        // Skip AVAudioFile setup — the test injects samples directly
        // into onLiveSamples; nothing should be writing to disk.
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
        // Snapshot the mic frame count BEFORE teardown so the caller can tell
        // a genuinely-empty mic session apart from a normal one. A fake
        // UI-test session never started the real mic, so report a non-zero
        // sentinel to keep `stopRecording` from tripping its empty-mic alert.
        let micFrames = isFakeForTesting ? 1 : mic.capturedFrameCount
        lastMicFrameCount = micFrames
        await mic.stop()
        await system.stop()
        micTask?.cancel(); micTask = nil
        systemTask?.cancel(); systemTask = nil
        timerTask?.cancel(); timerTask = nil

        await flushPendingSystemTail()
        recLog.log("stop: source=\(self.source.rawValue, privacy: .public) micFrames=\(micFrames, privacy: .public) writes=\(self.writesSinceStart, privacy: .public)")
        if (source == .microphone || source == .meeting) && micFrames == 0 {
            recLog.error("recording stopped with 0 microphone frames (source=\(self.source.rawValue, privacy: .public)) — dead/muted input device, wrong input selected, or failed format conversion")
        }
        let url = fileURL
        audioFile = nil
        fileURL = nil
        startTime = nil
        elapsed = 0
        isFakeForTesting = false
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
        isFakeForTesting = false
        pendingSystem.removeAll(keepingCapacity: false)
        state = .idle
    }

    // MARK: - Mixing

    private func consumeMic(_ buffer: AVAudioPCMBuffer) async {
        let samples = AudioConvert.samples(from: buffer)
        await MainActor.run { self.micLevel = AudioMeter.level(from: buffer) }
        if source == .microphone {
            // Mic-only: the live feed and the saved file are both just the
            // mic, so drive the live transcriber here and write directly.
            if let onLive = onLiveSamples { onLive(samples[0..<samples.count]) }
            await write(samples)
            return
        }
        // Meeting mode: the mic is the master clock. Each mic chunk pulls an
        // equal span of system audio out of `pendingSystem` (silence where
        // the app wasn't playing) and mixes the two, then drives BOTH the
        // saved file and the live transcriber with the result. Driving the
        // mix off the mic's steady 16kHz cadence — rather than the old
        // min(pendingMic, pendingSystem) pairing — means the live feed can't
        // starve when the system leg goes quiet, and the app-audio side now
        // reaches the live pane instead of only the on-disk WAV.
        let mixed = mixWithBufferedSystem(mic: samples)
        if let onLive = onLiveSamples { onLive(mixed[0..<mixed.count]) }
        await write(mixed)
    }

    private func consumeSystem(_ buffer: AVAudioPCMBuffer) async {
        let samples = AudioConvert.samples(from: buffer)
        await MainActor.run { self.systemLevel = AudioMeter.level(from: buffer) }
        if source == .systemAudio {
            // No mic to clock against — system audio IS the recording.
            // write() drives the live feed for `.systemAudio`.
            await write(samples)
            return
        }
        // Meeting mode: park the system audio for the mic clock to consume
        // in `consumeMic`. Bound the backlog so a stalled mic clock can't grow
        // it without limit. The cap is generous (~30s), so an SCK burst at
        // session start or slow clock skew just delays app audio until the mic
        // clock catches up — it isn't dropped. Trimming only happens if the
        // mic clock is genuinely stuck, and we log it so it's not silent.
        pendingSystem.append(contentsOf: samples)
        if pendingSystem.count > maxPendingSystem {
            let dropped = pendingSystem.count - maxPendingSystem
            pendingSystem.removeFirst(dropped)
            recLog.error("system jitter buffer overflow — dropped \(dropped, privacy: .public) samples (mic clock stalled?)")
        }
    }

    /// Mix one mic chunk with the head of the buffered system audio and
    /// consume the system samples used. Where both legs overlap they're
    /// averaged (×0.5, so a simultaneously-loud mic + app can't clip); where
    /// no system audio is buffered the mic is kept at FULL scale (never
    /// halved). Drives both the saved WAV and the live transcriber with the
    /// same result.
    private func mixWithBufferedSystem(mic: [Float]) -> [Float] {
        let n = mic.count
        let take = min(n, pendingSystem.count)
        var mixed = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if i < take {
                // Both legs present → average so a simultaneous loud mic + app
                // can't clip past ±1.0.
                mixed[i] = (mic[i] + pendingSystem[i]) * 0.5
            } else {
                // No app audio buffered for this span → keep the mic at FULL
                // scale. Averaging here would silently halve the user's own
                // voice whenever the app is quiet, making a meeting capture
                // quieter than a plain voice memo of the same mic input.
                mixed[i] = mic[i]
            }
        }
        if take > 0 { pendingSystem.removeFirst(take) }
        return mixed
    }

    /// Flush any system audio still buffered when the mic clock stops
    /// (meeting mode only — `.microphone` / `.systemAudio` write inline, so
    /// `pendingSystem` is empty for them). The mic is already torn down by
    /// the time `stop()` calls this, so the trailing span is system-only and
    /// goes out at full scale (the same way mic-only spans are written full
    /// scale in `mixWithBufferedSystem`), so the last bit of app audio isn't
    /// lost.
    private func flushPendingSystemTail() async {
        guard !pendingSystem.isEmpty else { return }
        let tail = pendingSystem
        pendingSystem.removeAll(keepingCapacity: false)
        if let onLive = onLiveSamples { onLive(tail[0..<tail.count]) }
        await write(tail)
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
            recLog.error("audio file write error: \(error.localizedDescription, privacy: .public)")
        }
        // Live-transcription feed: `.microphone` and `.meeting` fire
        // `onLiveSamples` from `consumeMic` (the latter with the mic+system
        // mix, so app audio reaches the live pane). `.systemAudio` has no
        // mic clock, so it drives the live feed from here instead.
        if source == .systemAudio, let onLive = onLiveSamples {
            onLive(samples[0..<samples.count])
        }
    }
}
