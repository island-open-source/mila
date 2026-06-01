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
    /// `true` while the system-audio (ScreenCaptureKit) leg of a meeting
    /// recording is feeding samples. Flips to `false` if the silence
    /// monitor drops the leg after a quiet window. Stays `true` for
    /// `.systemAudio` source recordings (no monitor) and is unused for
    /// `.microphone`. UI tests observe this flag (indirectly via the
    /// silence status file) to verify the auto-drop path fires.
    @Published private(set) var systemAudioActive: Bool = false

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

    /// Override for the silence-monitor window. `nil` keeps the default
    /// (5 minutes). UI tests set this to 10 seconds via a launch arg so
    /// the drop can be observed in test budget.
    var silenceWindowSecondsOverride: TimeInterval?
    private var silenceMonitor: AppAudioSilenceMonitor?

    /// UI-test inspection seam. When set, the session writes "active"
    /// to this file when the system-audio leg starts and "dropped"
    /// when the silence monitor tears it down. UI tests poll the file
    /// because OSLog isn't readable from XCUITest. nil in production.
    var silenceStatusFileURL: URL?
    private var fakeMeetingTonePumpTask: Task<Void, Never>?

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
            systemAudioActive = true
            writeSilenceStatus("active")
            systemTask = Task { [weak self] in
                guard let self else { return }
                for await buf in self.system.audioStream {
                    await self.consumeSystem(buf)
                }
            }
            // Only meetings get the silence monitor. A `.systemAudio`-only
            // recording is the user explicitly choosing system audio, so
            // dropping it would leave nothing recording at all — wrong
            // behaviour. Meetings have the mic as a fallback, which is the
            // whole reason the auto-drop is safe.
            if source == .meeting {
                installSilenceMonitor()
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

    /// UI-test seam: simulate a meeting recording without
    /// AVAudioEngine or ScreenCaptureKit. Arms the silence monitor
    /// against the configured `silenceWindowSecondsOverride` and, if
    /// `withSystemAudio` is true, pumps a synthetic 0.05-amplitude
    /// buffer at 20 Hz so the monitor observes "audio is real" before
    /// its window expires. With `withSystemAudio = false` the monitor
    /// sees zero buffers and fires the drop path.
    ///
    /// Combined with `silenceStatusFileURL`, the test process polls
    /// the file to verify which branch was taken without needing
    /// accessibility-tree hooks into RecordingSession's internals.
    func startFakeMeetingForTesting(outputURL: URL, withSystemAudio: Bool) async {
        guard state == .idle else { return }
        self.source = .meeting
        self.fileURL = outputURL
        self.writesSinceStart = 0
        // Skip AVAudioFile setup — this path doesn't write a WAV;
        // the test only cares about the silence-monitor wiring.
        startTime = Date()
        systemAudioActive = true
        writeSilenceStatus("active")
        installSilenceMonitor()
        if withSystemAudio {
            // Pump a synthetic 0.05-amplitude buffer at 20Hz into the
            // monitor only. Each buffer is 800 samples — well above the
            // 0.001 RMS threshold so the monitor short-circuits on the
            // very first ingest and the window will end with "audio
            // present, keep capture". The format is hoisted out of the
            // loop because `WhisperAudioFormat.pcmFloat32` constructs a
            // new `AVAudioFormat` each access.
            let format = WhisperAudioFormat.pcmFloat32
            fakeMeetingTonePumpTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let monitor = self?.silenceMonitor else { return }
                    if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800) {
                        buf.frameLength = 800
                        if let ch = buf.floatChannelData?[0] {
                            for i in 0..<800 { ch[i] = 0.05 }
                        }
                        monitor.ingest(buffer: buf)
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
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

    /// Build + arm a new silence monitor. Factored out so both the
    /// production `start()` and the UI-test fake-meeting seam share
    /// the same wiring (window resolution, drop callback,
    /// status-file notification on `dropSystemAudioLeg`).
    private func installSilenceMonitor() {
        let window = silenceWindowSecondsOverride ?? AppAudioSilenceMonitor.defaultWindowSeconds
        // The monitor's onDrop is invoked on the main actor (it fires
        // out of `evaluate()` inside a `Task { @MainActor }` deadline),
        // and `dropSystemAudioLeg` is itself `@MainActor` — so we just
        // hop a Task to satisfy the sync-closure -> async-method
        // boundary. `[weak self]` so a monitor that outlives the
        // session (it shouldn't, but cancel() can race with dealloc)
        // can't pin us.
        let monitor = AppAudioSilenceMonitor(windowSeconds: window) { [weak self] in
            Task { @MainActor in
                await self?.dropSystemAudioLeg()
            }
        }
        silenceMonitor = monitor
        monitor.start()
    }

    func stop() async -> URL? {
        guard state == .recording else { return fileURL }
        state = .stopping
        silenceMonitor?.cancel(); silenceMonitor = nil
        fakeMeetingTonePumpTask?.cancel(); fakeMeetingTonePumpTask = nil
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
        systemAudioActive = false
        state = .idle
        return url
    }

    /// Tear down any active capture without trying to flush a final WAV.
    /// Used by the AppDelegate at terminate time so we hand the user's mic
    /// and screen-recording grants back to macOS instead of leaving them
    /// pinned by a half-running session.
    func cancelAll() async {
        guard state != .idle else { return }
        silenceMonitor?.cancel(); silenceMonitor = nil
        fakeMeetingTonePumpTask?.cancel(); fakeMeetingTonePumpTask = nil
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
        systemAudioActive = false
        state = .idle
    }

    // MARK: - Mixing

    private func consumeMic(_ buffer: AVAudioPCMBuffer) async {
        let samples = AudioConvert.samples(from: buffer)
        await MainActor.run { self.micLevel = AudioMeter.level(from: buffer) }
        // Live-transcription feed is driven by the mic in ALL modes that
        // include a mic (`.microphone` and `.meeting`). In meeting mode
        // the file still mixes mic+system when paired, but the live
        // feed must NOT wait on the pair — observed bug (1 Jun 2026):
        // when the system-audio leg is silent (e.g. user is the only
        // speaker), `flushPending` keeps `min(pendingMic, pendingSystem)
        // == 0` so `write()` is never called and onLiveSamples never
        // fires. Pressing Stop then flushes ~60s of buffered mic as one
        // giant write, and the live pane shows nothing during the
        // recording. Tradeoff: in meeting mode, live transcription only
        // covers the mic side — the saved WAV still has the mix and
        // gets a full post-recording transcription pass.
        if let onLive = onLiveSamples {
            onLive(samples[0..<samples.count])
        }
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
        // Feed the silence monitor before the mixer — the monitor only
        // looks at raw RMS and short-circuits once it's seen audio, so
        // the cost during a normal meeting is negligible.
        silenceMonitor?.ingest(buffer: buffer)
        if source == .systemAudio {
            await write(samples)
        } else {
            pendingSystem.append(contentsOf: samples)
            await flushPending(force: false)
        }
    }

    /// Tear down the system-audio leg while the recording stays alive on
    /// the microphone. Used by `AppAudioSilenceMonitor` when the opening
    /// window passed without any audio above the threshold — the user
    /// (almost certainly) picked the wrong app or started recording
    /// before the meeting began, and the cleaner UX is to seamlessly
    /// fall back to mic-only.
    ///
    /// Flips `source` to `.microphone` so subsequent mic samples are
    /// written directly instead of accumulating in `pendingMic` waiting
    /// for a matching `pendingSystem` chunk that will never arrive.
    /// Any pending mic samples are flushed by `flushPending(force: true)`
    /// — they're "leftover" from the mixer's pair-wait logic, not
    /// stale, and dropping them would silently lose a couple of seconds
    /// of the user's voice from the start of the recording.
    func dropSystemAudioLeg() async {
        guard state == .recording, source == .meeting else { return }
        recLog.log("dropping system audio leg — silence window elapsed")
        await system.stop()
        systemTask?.cancel(); systemTask = nil
        silenceMonitor?.cancel(); silenceMonitor = nil
        fakeMeetingTonePumpTask?.cancel(); fakeMeetingTonePumpTask = nil
        // Drain whatever mic samples were sitting paired with absent
        // system samples. force=true also empties pendingSystem, which
        // should be empty (since we got here) but the call is cheap and
        // keeps things tidy.
        await flushPending(force: true)
        source = .microphone
        systemAudioActive = false
        systemLevel = 0
        writeSilenceStatus("dropped")
    }

    /// Write the current system-audio leg status to the inspection
    /// file, if one was configured. No-op in production. Errors are
    /// swallowed — UI tests will time out and the failure message
    /// will point to the missing/wrong file anyway.
    private func writeSilenceStatus(_ value: String) {
        guard let url = silenceStatusFileURL else { return }
        try? value.data(using: .utf8)?.write(to: url, options: .atomic)
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
        // Note: onLiveSamples is NOT fired here. Live-transcription feed
        // is driven by `consumeMic` / `consumeSystem` directly so the
        // pair-wait for file mixing in meeting mode can't starve the
        // live pane. See `consumeMic` for the meeting-mode rationale.
        if source == .systemAudio, let onLive = onLiveSamples {
            // For systemAudio-only recordings (no mic) we need this
            // path to drive the live feed since `consumeMic` doesn't run.
            onLive(samples[0..<samples.count])
        }
    }
}
