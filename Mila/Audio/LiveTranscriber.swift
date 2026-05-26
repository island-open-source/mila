import Foundation
import Combine
import OSLog
import TranscriptionCore

private let liveLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "LiveTranscriber")

/// Per-tick output of the live transcriber. Kept around for back-compat
/// with `LiveSpeakerDiarizer` (which still publishes intervals that view
/// code may want to consume) and the unit tests. The view layer reads
/// `fullText`, not segments.
struct LiveSegment: Identifiable, Hashable {
    let id: UUID
    var startSeconds: Double
    var endSeconds: Double
    var text: String
    var speaker: String?
    var stable: Bool
}

/// Streams whisper output during a recording and ACCUMULATES timed
/// segments across ticks. Every `chunkSeconds`, we transcribe the
/// trailing `windowSeconds` of audio. Whisper returns multiple
/// timestamped segments per window; we merge them into a growing
/// `segments` list using time-based dedup against what we already
/// have. This preserves per-utterance timing for the live UI (one
/// line per segment) and for downstream consumers (e.g. matching
/// speakers to segments by time once live diarization comes back).
///
/// Merge rules per incoming segment (windowAbsoluteStart added so its
/// `start` / `end` are absolute recording-time seconds):
///   * If it overlaps the LAST existing segment by start time AND its
///     end extends further, REPLACE the last segment (whisper got more
///     audio and decided the same utterance is longer).
///   * Else if its start is strictly past the last segment's end, APPEND.
///   * Else (start is well before last.end, not a longer rewrite),
///     SKIP — same content we already have from a previous tick.
@MainActor
final class LiveTranscriber: ObservableObject {
    /// Accumulated, growing transcript. Drives the live transcript pane.
    @Published private(set) var fullText: String = ""
    /// Set true while a whisper call is in flight — drives the
    /// "thinking" indicator in the UI.
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var lastError: String?

    /// Authoritative per-utterance list with whisper's absolute
    /// recording-time start/end. The live view renders one line per
    /// entry; `fullText` is a derived join of `segments.map(\.text)`
    /// kept in sync for back-compat with callers that still want one
    /// flat string (e.g. the LLM feed via `formattedTranscript`).
    @Published private(set) var segments: [LiveSegment] = []

    var chunkSeconds: Double = 5.0
    var windowSeconds: Double = 30.0
    private let sampleRate: Double = 16_000

    private let transcription: TranscriptionService
    /// Rolling window of recent samples — we keep only the last
    /// `windowSeconds` worth (plus a small headroom; see `trimBuffer`)
    /// because anything older was already transcribed and merged. For
    /// a 1-hour meeting at 16 kHz f32 the full unbounded buffer would
    /// be ~230 MB; with trimming it caps at ~2 MB regardless of
    /// recording length. Caught by Cursor Bugbot in PR #20.
    private var buffer: [Float] = []
    /// Sample-index of `buffer[0]` in absolute recording time. When
    /// the trim drops the head of `buffer`, we bump this by the same
    /// amount so `windowAbsoluteStart` in `runOnce` keeps producing
    /// correct absolute timestamps for the segment merge.
    private var samplesDropped: Int = 0
    private var inFlight: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var language: String = "he"

    init(transcription: TranscriptionService) {
        self.transcription = transcription
    }

    /// Inject canned segments without touching whisper. Used by the
    /// UI test for Hebrew RTL alignment (see `--ui-test-rtl-live-hebrew`
    /// path in `MilaApp.init`). Production paths must not call this.
    func seedForTesting(_ initial: [LiveSegment]) {
        self.segments = initial
        self.fullText = initial.map(\.text).joined(separator: " ")
    }

    func start(language: String) {
        stop()
        self.language = language
        self.buffer.removeAll(keepingCapacity: true)
        self.samplesDropped = 0
        self.fullText = ""
        self.segments = []
        self.lastError = nil
        liveLog.log("LiveTranscriber.start lang=\(language, privacy: .public) chunk=\(self.chunkSeconds, privacy: .public)s window=\(self.windowSeconds, privacy: .public)s")

        tickTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.chunkSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.kickIfIdle()
            }
        }
    }

    @discardableResult
    func stop() -> String {
        tickTask?.cancel()
        tickTask = nil
        inFlight?.cancel()
        inFlight = nil
        return fullText
    }

    func ingest(_ samples: ArraySlice<Float>) {
        buffer.append(contentsOf: samples)
    }

    func transcribeNow() async {
        await runOnce()
    }

    /// Idempotent end-of-recording flush. The cumulative model doesn't
    /// have "tentative" segments to promote, but the dictation flow
    /// still calls this — keep as a no-op.
    func finalizeAllSegments() {}

    /// No-op in the cumulative model. Live speaker labels can't attach
    /// to a flat text stream without per-character timing. The full
    /// pyannote pass after the recording stops is what produces the
    /// saved transcript's speaker labels in the detail view.
    func applySpeakerLabels(_ intervals: [(start: Double, end: Double, speaker: String)]) {
        _ = intervals
    }

    /// Used by `LiveAISession` as the LLM-feed format. Newline-separated
    /// so the LLM can see utterance boundaries, with `[mm:ss]` prefix
    /// per line for time anchoring.
    var formattedTranscript: String {
        segments.map { seg in
            let mm = Int(seg.startSeconds) / 60
            let ss = Int(seg.startSeconds) % 60
            return String(format: "[%02d:%02d] %@", mm, ss, seg.text)
        }.joined(separator: "\n")
    }

    private func kickIfIdle() {
        guard inFlight == nil else {
            liveLog.log("LiveTranscriber.kickIfIdle SKIP: tick already in flight")
            return
        }
        inFlight = Task { @MainActor [weak self] in
            await self?.runOnce()
            self?.inFlight = nil
        }
    }

    private func runOnce() async {
        let total = buffer.count
        // Need at least 1s of audio before whisper produces anything
        // useful — below that, segment timestamps are garbage and the
        // first-tick noise burst would otherwise show up as gibberish
        // in the UI.
        let minSamples = Int(sampleRate)
        guard total >= minSamples else {
            liveLog.log("LiveTranscriber.runOnce SKIP: buffer=\(total) < \(minSamples) samples")
            return
        }
        isTranscribing = true
        defer { isTranscribing = false }

        let windowSamples = Int(windowSeconds * sampleRate)
        let windowStartIndex = max(0, total - windowSamples)
        let windowAbsoluteStart = Double(samplesDropped + windowStartIndex) / sampleRate
        let slice = Array(buffer[windowStartIndex..<total])

        let startedAt = Date()
        let whisperSegs = await transcription.transcribeOnceSegments(samples: slice, language: language)
        let elapsed = Date().timeIntervalSince(startedAt)
        liveLog.log("LiveTranscriber tick: samples=\(slice.count) elapsed=\(elapsed, privacy: .public)s segments=\(whisperSegs.count) lang=\(self.language, privacy: .public)")
        guard !whisperSegs.isEmpty else { return }

        let absoluteSegs: [LiveSegment] = whisperSegs.compactMap { s in
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LiveSegment(
                id: UUID(),
                startSeconds: windowAbsoluteStart + s.start,
                endSeconds: windowAbsoluteStart + s.end,
                text: text,
                speaker: nil,
                stable: true
            )
        }
        Self.merge(incoming: absoluteSegs, into: &segments)
        fullText = segments.map(\.text).joined(separator: " ")
        trimBuffer()
    }

    /// Drop samples from the head of `buffer` that we'll never read
    /// again. Anything older than the rolling whisper window is dead
    /// weight; keeping it grows the buffer linearly with recording
    /// length (Cursor Bugbot, PR #20).
    ///
    /// Keeps `windowSeconds` of samples (everything the next tick's
    /// slice could possibly need) plus a half-chunk of headroom so
    /// we don't churn the array every single tick when the buffer is
    /// only just past the window size.
    private func trimBuffer() {
        let keep = Int(windowSeconds * sampleRate) + Int(chunkSeconds * sampleRate / 2)
        guard buffer.count > keep else { return }
        let drop = buffer.count - keep
        buffer.removeFirst(drop)
        samplesDropped += drop
    }

    /// Merge `incoming` (already in absolute time) into `existing`.
    /// Rules in the file header — exposed for tests.
    /// - `sameUtteranceStartTolerance`: how close two segment starts
    ///   have to be to be considered "the same utterance whisper just
    ///   re-emitted with more audio." 0.6s matches whisper's typical
    ///   start-time jitter across overlapping windows.
    /// - `appendGapTolerance`: how strictly past the last existing
    ///   segment a new one has to start to be considered new content.
    ///   0.2s of slack absorbs jitter without letting clearly-overlap
    ///   text through.
    static func merge(
        incoming: [LiveSegment],
        into existing: inout [LiveSegment],
        sameUtteranceStartTolerance: Double = 0.6,
        appendGapTolerance: Double = 0.2
    ) {
        for seg in incoming {
            if let last = existing.last,
               abs(last.startSeconds - seg.startSeconds) <= sameUtteranceStartTolerance,
               seg.endSeconds > last.endSeconds {
                // Same utterance, whisper now has more audio → replace.
                var updated = last
                updated.endSeconds = seg.endSeconds
                updated.text = seg.text
                existing[existing.count - 1] = updated
                continue
            }
            let cutoff = existing.last.map { $0.endSeconds - appendGapTolerance } ?? -.infinity
            if seg.startSeconds >= cutoff {
                existing.append(seg)
            }
            // Otherwise the incoming segment is fully inside content we
            // already finalized — skip.
        }
    }
}
