import Foundation
import TranscriptionCore
@testable import Mila

/// In-memory stand-in for `WhisperEngine` so transcription tests don't have to
/// load a 1.5GB model from disk. Records every call for assertions.
actor StubWhisperEngine: TranscribingEngine {

    // MARK: - Test-controlled inputs

    /// Segments returned by the next `transcribe` call. Keyed in FIFO order:
    /// first call gets `cannedQueue[0]`, second gets `cannedQueue[1]`, etc.
    /// Falls back to `defaultCanned` once the queue is exhausted.
    var cannedQueue: [[TranscriptSegment]] = []
    var defaultCanned: [TranscriptSegment] = [
        TranscriptSegment(start: 0, end: 1, text: "stub")
    ]
    /// Per-call simulated work duration. Falls back to `defaultDelay`.
    var delayQueue: [Double] = []
    var defaultDelay: Double = 0
    /// If non-nil at the time of the next call, that call throws.
    var nextError: Error?
    /// Simulated `loadIfNeeded` duration. When > 0, `loadIfNeeded`
    /// invokes the `preparationObserver` with `true`, sleeps, then
    /// invokes it with `false` — mirrors the real engine's behaviour
    /// on a first-time CoreML compile. Used by the preparing-state
    /// regression test in `TranscriptionServicePrewarmTests`.
    var loadDelay: Double = 0
    /// Status string surfaced through the preparation observer. Lets
    /// a test assert that the engine-supplied caption reaches the UI.
    var loadPreparationStatus: String? = "Preparing Neural Engine…"

    // MARK: - Recorded outputs

    private(set) var loadedModel: URL?
    private(set) var loadCallCount = 0
    private(set) var transcribeCalls: [(samples: [Float], language: String, audioCtx: Int32?)] = []
    private(set) var concurrentInFlight = 0
    private(set) var maxConcurrentInFlight = 0
    private(set) var shutdownCount = 0

    // MARK: - Preparation observer

    private var preparationObserver: (@Sendable (Bool, String?) -> Void)?

    func setPreparationObserver(_ observer: (@Sendable (Bool, String?) -> Void)?) {
        self.preparationObserver = observer
    }

    // MARK: - TranscribingEngine

    func loadIfNeeded(modelURL: URL, displayName: String) async throws {
        loadCallCount += 1
        loadedModel = modelURL
        if loadDelay > 0 {
            preparationObserver?(true, loadPreparationStatus)
            try? await Task.sleep(nanoseconds: UInt64(loadDelay * 1_000_000_000))
            preparationObserver?(false, nil)
        }
    }

    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        if let err = nextError {
            nextError = nil
            throw err
        }

        concurrentInFlight += 1
        maxConcurrentInFlight = max(maxConcurrentInFlight, concurrentInFlight)
        defer { concurrentInFlight -= 1 }

        transcribeCalls.append((samples: samples, language: language, audioCtx: audioCtx))

        let delay = delayQueue.isEmpty ? defaultDelay : delayQueue.removeFirst()
        if delay > 0 {
            let steps = 4
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000 / Double(steps)))
                // Mirror the real engine: bail out cleanly if the caller has
                // flipped the cancellation flag while we were sleeping.
                if isCancelled?() == true { throw CancellationError() }
                progress?(Float(i) / Float(steps))
            }
        } else {
            if isCancelled?() == true { throw CancellationError() }
            progress?(1.0)
        }

        let segments = cannedQueue.isEmpty ? defaultCanned : cannedQueue.removeFirst()
        return segments
    }

    func shutdown() async {
        shutdownCount += 1
        loadedModel = nil
    }

    // MARK: - Test helpers

    func setCannedQueue(_ q: [[TranscriptSegment]]) { cannedQueue = q }
    func setDefaultCanned(_ s: [TranscriptSegment]) { defaultCanned = s }
    func setDelayQueue(_ q: [Double]) { delayQueue = q }
    func setDefaultDelay(_ d: Double) { defaultDelay = d }
    func setNextError(_ e: Error?) { nextError = e }
    func setLoadDelay(_ d: Double) { loadDelay = d }
    func setLoadPreparationStatus(_ s: String?) { loadPreparationStatus = s }
    func resetRecording() {
        loadCallCount = 0
        loadedModel = nil
        transcribeCalls.removeAll()
        concurrentInFlight = 0
        maxConcurrentInFlight = 0
    }
}
