import Foundation
import AVFoundation
import Combine
import os

private let micLog = MilaLog(category: "MicrophoneRecorder")

enum MicrophoneError: Error, Equatable {
    case noInputDevice
    case bringUpTimedOut
}

/// Per-session capture counters. The audio tap (a realtime thread) is the
/// only writer; the main actor reads a snapshot after `stop()`. Held behind
/// an `OSAllocatedUnfairLock` so the per-buffer update never hops actors.
/// Surfaced in the diagnostic log so a "0-second failed recording" can be
/// told apart from "device delivered no buffers" vs "every buffer failed
/// format conversion" — the three look identical on disk (an empty WAV) but
/// have completely different fixes.
struct MicFrameStats: Sendable {
    var buffers = 0
    var frames = 0
    var conversionFailures = 0
}

/// Pulls samples from the user's preferred input device using `AVAudioEngine`.
/// Emits whisper-format buffers (16kHz mono Float32) on `audioStream`.
///
/// **Important:** every `start()` call builds a brand-new `AVAudioEngine` and
/// a brand-new `AsyncStream`. Reusing a single engine across stop/start cycles
/// is a documented macOS quirk that makes the input node go silent after the
/// first session — the user-visible symptom was "first Voice Memo records
/// fine, every subsequent one captures ~60ms of noise and Whisper hallucinates
/// the same Hebrew test phrase for all of them".
///
/// **Threading:** the heavy CoreAudio bring-up (`inputFormat(forBus:)`,
/// `installTap`, `engine.prepare()`, `engine.start()`) runs OFF the main
/// actor inside a `Task.detached`, with a hard timeout. CoreAudio can stall
/// indefinitely when the input device is a wireless mic mid-profile-switch
/// (Bluetooth headset moving between A2DP and HFP, AirPods waking up, etc.);
/// before this fix, a stalled CoreAudio call froze the entire main thread
/// and made the app unresponsive — including the global hotkeys.
@MainActor
final class MicrophoneRecorder: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0

    /// Current stream — replaced on every `start()` so leftover buffered
    /// samples from a previous recording can never leak into the next one.
    private(set) var audioStream: AsyncStream<AVAudioPCMBuffer>
    private var audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private var engine: AVAudioEngine?

    /// Capture counters for the current/most-recent session, rebuilt on every
    /// `start()`. Left intact across `stop()` so the orchestrator can read
    /// `capturedFrameCount` after teardown.
    private var stats: OSAllocatedUnfairLock<MicFrameStats>?

    /// Whisper-format frames the tap has yielded to consumers this session.
    /// 0 after a recording means the mic produced nothing — a dead/muted
    /// device, the wrong input selected, or a failing format conversion.
    var capturedFrameCount: Int { stats?.withLock { $0.frames } ?? 0 }

    /// How long we'll wait for the AVAudioEngine bring-up before giving up
    /// and throwing `MicrophoneError.bringUpTimedOut`. CoreAudio can stall
    /// indefinitely on wireless mic profile switches; we'd rather throw
    /// (caller beeps, user retries) than freeze the app.
    var bringUpTimeout: TimeInterval = 5.0

    /// Test seam: when set, replaces the real `AVAudioEngine` bring-up so
    /// `MicrophoneRecorderTests` can simulate slow / stalled / failing
    /// CoreAudio without needing a real microphone or fragile timing in CI.
    var bringUpOverride: (@Sendable () async throws -> Void)?

    /// Smoothed digital gain applied to every captured float frame before
    /// it's yielded to consumers. Built fresh on each `start()` so a low-
    /// volume mic doesn't inherit a stale gain from a previous session.
    /// Held here (rather than rebuilt inside the tap closure) so tests and
    /// the level meter can observe `currentGain` while a recording is in
    /// flight.
    private(set) var gain: AdaptiveGainController?

    init() {
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.audioStream = AsyncStream { continuation = $0 }
        self.audioContinuation = continuation
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func start() async throws {
        guard !isRunning else { return }

        // Tear down anything that may still be alive from a previous session
        // (defensive — `stop()` should have done this, but a partially-started
        // session that threw mid-way could leak engine/tap state). All cheap,
        // can stay on the main actor.
        if let existing = engine {
            existing.inputNode.removeTap(onBus: 0)
            existing.stop()
            engine = nil
        }
        audioContinuation.finish()

        var newContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.audioStream = AsyncStream { newContinuation = $0 }
        self.audioContinuation = newContinuation
        let continuationForTap = newContinuation!

        if let override = bringUpOverride {
            try await Self.withTimeout(seconds: bringUpTimeout) {
                try await override()
            }
            isRunning = true
            return
        }

        // The level callback hops back to the main actor for the @Published
        // mutation. Captured weakly so a deinit'd recorder doesn't keep the
        // tap closure alive.
        let onLevel: @Sendable (Float) -> Void = { [weak self] lvl in
            Task { @MainActor in self?.level = lvl }
        }

        // Build a fresh AGC for this session. Pulls the persisted toggle
        // straight from UserDefaults so the recorder doesn't need to capture
        // a main-actor settings object onto the audio thread. Matches the
        // pattern already used here for `audio.input.preferredUID`.
        let agcEnabled: Bool = {
            if UserDefaults.standard.object(forKey: AudioInputSettings.adaptiveGainEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: AudioInputSettings.adaptiveGainEnabledKey)
        }()
        let agc = AdaptiveGainController(enabled: agcEnabled)
        self.gain = agc

        let sessionStats = OSAllocatedUnfairLock(initialState: MicFrameStats())
        self.stats = sessionStats

        let result = try await Self.withTimeout(seconds: bringUpTimeout) {
            try await Self.realBringUp(continuation: continuationForTap,
                                       onLevel: onLevel,
                                       gain: agc,
                                       stats: sessionStats)
        }
        self.engine = result.engine
        isRunning = true
        micLog.log("mic started: \(result.format.sampleRate, privacy: .public)Hz \(result.format.channelCount, privacy: .public)ch agc=\(agcEnabled ? "on" : "off", privacy: .public)")
    }

    func stop() async {
        guard isRunning else { return }
        if let s = stats?.withLock({ $0 }) {
            micLog.log("mic stopping: buffers=\(s.buffers, privacy: .public) frames=\(s.frames, privacy: .public) conversionFailures=\(s.conversionFailures, privacy: .public)")
            if s.frames == 0 {
                micLog.error("microphone delivered NO audio this session (buffers=\(s.buffers, privacy: .public), conversionFailures=\(s.conversionFailures, privacy: .public)) — the recording will be empty")
            }
        }
        let toTeardown = engine
        engine = nil
        gain = nil
        audioContinuation.finish()
        isRunning = false
        level = 0
        // Tear down off-main as well: `engine.stop()` can block on the same
        // CoreAudio HAL queue that `start()` blocks on, especially while a
        // Bluetooth mic is mid-profile-teardown.
        if let toTeardown {
            await Task.detached(priority: .userInitiated) {
                toTeardown.inputNode.removeTap(onBus: 0)
                toTeardown.stop()
            }.value
        }
    }

    deinit {
        audioContinuation.finish()
    }

    // MARK: - Off-main bring-up

    /// Box for handing the freshly-created `AVAudioEngine` + format back from
    /// the detached task to the main actor. `AVAudioEngine` and `AVAudioFormat`
    /// aren't formally `Sendable` but we're only crossing the boundary once,
    /// at construction time, before either side touches the references again.
    private struct EngineBox: @unchecked Sendable {
        let engine: AVAudioEngine
        let format: AVAudioFormat
    }

    private static func realBringUp(
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        onLevel: @escaping @Sendable (Float) -> Void,
        gain: AdaptiveGainController,
        stats: OSAllocatedUnfairLock<MicFrameStats>
    ) async throws -> EngineBox {
        // Read the user's pinned input UID off the main actor — UserDefaults
        // is thread-safe and Settings writes via a @MainActor object, so the
        // value we see here is at worst one start() stale.
        let preferredUID = UserDefaults.standard.string(forKey: "audio.input.preferredUID")
        return try await Task.detached(priority: .userInitiated) { () -> EngineBox in
            let engine = AVAudioEngine()
            let input = engine.inputNode
            if let device = AudioDeviceManager.preferredInputDevice(preferredUID: preferredUID) {
                do {
                    try AudioDeviceManager.setInputDevice(device, on: engine)
                    micLog.log("input device: \(device.name, privacy: .public) [\(device.manufacturer, privacy: .public)] uid=\(device.uid, privacy: .public)")
                } catch {
                    micLog.error("could not switch to \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public) — falling back to AVAudioEngine default input")
                }
            } else {
                micLog.log("input device: AVAudioEngine default (no connected device matched the preferred UID)")
            }
            let nativeFormat = input.inputFormat(forBus: 0)
            micLog.log("native input format: \(nativeFormat.sampleRate, privacy: .public)Hz \(nativeFormat.channelCount, privacy: .public)ch")
            guard nativeFormat.sampleRate > 0 else {
                micLog.error("input format reports sampleRate=0 — no usable input device; throwing noInputDevice")
                throw MicrophoneError.noInputDevice
            }
            input.installTap(onBus: 0,
                             bufferSize: 4096,
                             format: nativeFormat) { buffer, _ in
                onLevel(AudioMeter.level(from: buffer))
                do {
                    let converted = try AudioConvert.toWhisperFormat(buffer)
                    // Apply adaptive digital gain in-place on the whisper-
                    // format buffer so the WAV writer AND the live VAD/
                    // whisper feed both see the same boosted signal —
                    // single source of truth. `toWhisperFormat` allocates
                    // a fresh buffer in every real-mic path (mics never
                    // come up at native 16kHz mono float), so writing into
                    // it doesn't touch the engine-owned source buffer.
                    // The defensive `aliasesInput` check covers the rare
                    // exotic-device case where the formats happen to match.
                    let toMutate: AVAudioPCMBuffer
                    if converted === buffer {
                        toMutate = Self.copyBuffer(buffer) ?? converted
                    } else {
                        toMutate = converted
                    }
                    if let channel = toMutate.floatChannelData?[0] {
                        gain.process(channel, count: Int(toMutate.frameLength))
                    }
                    let yielded = Int(toMutate.frameLength)
                    let isFirst = stats.withLock { s -> Bool in
                        s.buffers += 1
                        s.frames += yielded
                        return s.buffers == 1
                    }
                    if isFirst {
                        micLog.log("first mic buffer delivered (\(yielded, privacy: .public) frames) — capture is live")
                    }
                    continuation.yield(toMutate)
                } catch {
                    // Don't log every dropped buffer (could be thousands) —
                    // log the first, and `stop()` reports the running total.
                    let failures = stats.withLock { s -> Int in
                        s.conversionFailures += 1
                        return s.conversionFailures
                    }
                    if failures == 1 {
                        micLog.error("mic buffer conversion failed (dropping frames): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            engine.prepare()
            try engine.start()
            micLog.log("AVAudioEngine started; tap installed, awaiting buffers")
            return EngineBox(engine: engine, format: nativeFormat)
        }.value
    }

    /// Deep-copy a Float32 PCM buffer so we can apply in-place gain without
    /// mutating an engine-owned source buffer. Only used on the rare path
    /// where the input device already delivers whisper-format audio.
    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format,
                                          frameCapacity: source.frameCapacity) else {
            return nil
        }
        copy.frameLength = source.frameLength
        let channels = Int(source.format.channelCount)
        guard let src = source.floatChannelData, let dst = copy.floatChannelData else {
            return nil
        }
        let count = Int(source.frameLength)
        for ch in 0..<channels {
            dst[ch].update(from: src[ch], count: count)
        }
        return copy
    }

    /// Race `operation` against a sleep; whichever completes first wins.
    /// On timeout the in-flight operation is cancelled at the Swift-task
    /// level — note this does NOT actually unblock an underlying CoreAudio
    /// `dispatch_sync` if that's what's stalling. The detached worker
    /// thread may keep waiting (and the engine may never come up) until
    /// CoreAudio finally returns. The crucial thing is that the *main
    /// actor* is never blocked, so the UI / hotkeys stay responsive.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MicrophoneError.bringUpTimedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
