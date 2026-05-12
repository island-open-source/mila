import Foundation
import AVFoundation
import Combine

enum MicrophoneError: Error, Equatable {
    case noInputDevice
    case bringUpTimedOut
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

    /// How long we'll wait for the AVAudioEngine bring-up before giving up
    /// and throwing `MicrophoneError.bringUpTimedOut`. CoreAudio can stall
    /// indefinitely on wireless mic profile switches; we'd rather throw
    /// (caller beeps, user retries) than freeze the app.
    var bringUpTimeout: TimeInterval = 5.0

    /// Test seam: when set, replaces the real `AVAudioEngine` bring-up so
    /// `MicrophoneRecorderTests` can simulate slow / stalled / failing
    /// CoreAudio without needing a real microphone or fragile timing in CI.
    var bringUpOverride: (@Sendable () async throws -> Void)?

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

        let result = try await Self.withTimeout(seconds: bringUpTimeout) {
            try await Self.realBringUp(continuation: continuationForTap,
                                       onLevel: onLevel)
        }
        self.engine = result.engine
        isRunning = true
        print(String(format: "Mic: started (%.0fHz, %d ch)",
                     result.format.sampleRate, Int(result.format.channelCount)))
    }

    func stop() async {
        guard isRunning else { return }
        let toTeardown = engine
        engine = nil
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
        onLevel: @escaping @Sendable (Float) -> Void
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
                    print("Mic: using \(device.name) [\(device.manufacturer)]")
                } catch {
                    print("Mic: could not switch to \(device.name): \(error)")
                }
            }
            let nativeFormat = input.inputFormat(forBus: 0)
            guard nativeFormat.sampleRate > 0 else {
                throw MicrophoneError.noInputDevice
            }
            input.installTap(onBus: 0,
                             bufferSize: 4096,
                             format: nativeFormat) { buffer, _ in
                onLevel(AudioMeter.level(from: buffer))
                do {
                    let converted = try AudioConvert.toWhisperFormat(buffer)
                    continuation.yield(converted)
                } catch {
                    print("Mic conversion error: \(error)")
                }
            }
            engine.prepare()
            try engine.start()
            return EngineBox(engine: engine, format: nativeFormat)
        }.value
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
