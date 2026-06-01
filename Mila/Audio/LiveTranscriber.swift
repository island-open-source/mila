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
    /// "thinking" indicator in the UI. Backed by an internal counter
    /// (`activeTranscribeCount`) so concurrent transcribes don't
    /// trample each other: a stale call returning while a fresh one
    /// is in flight no longer flips the indicator off prematurely.
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var lastError: String?

    /// Number of currently-running transcribe invocations. Always
    /// mutated alongside `isTranscribing = (count > 0)` via
    /// `beginTranscribe()` / `endTranscribe()` so the published
    /// indicator reflects whether *any* transcribe is still in
    /// flight, not just whichever one returned last.
    private var activeTranscribeCount: Int = 0

    /// Authoritative per-utterance list with whisper's absolute
    /// recording-time start/end. The live view renders one line per
    /// entry; `fullText` is a derived join of `segments.map(\.text)`
    /// kept in sync for back-compat with callers that still want one
    /// flat string (e.g. the LLM feed via `formattedTranscript`).
    @Published private(set) var segments: [LiveSegment] = []

    var chunkSeconds: Double = 30.0
    var windowSeconds: Double = 30.0
    /// When true, route incoming audio through `UtteranceDetector` and
    /// transcribe once per detected utterance instead of on the fixed
    /// `chunkSeconds` timer. Set by `MilaApp.wireLiveAIPipeline` from
    /// `LiveAISettings.useVAD` before `start()`.
    var useVAD: Bool = false
    /// Fires alongside each VAD utterance transcribe with the same
    /// samples and absolute time range. Wired in `MilaApp` to feed
    /// `LiveSpeakerDiarizer.process(samples:startSeconds:endSeconds:)`
    /// — the diarizer needs utterance-shaped chunks to embed against
    /// its speaker pool. Each chunk should contain one speaker;
    /// VAD-bounded utterances satisfy that by construction.
    var onUtteranceCaptured: (([Float], Double, Double) -> Void)?
    private let sampleRate: Double = 16_000

    private let transcription: TranscriptionService
    private var detector: UtteranceDetector?
    /// VAD path serialises transcribes via task chaining: each new
    /// utterance creates a Task that awaits the previous one before
    /// running whisper. We never null this — Swift's runtime drops the
    /// chain naturally once each Task body completes.
    private var lastUtteranceTask: Task<Void, Never>?
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
    /// Incremented on every `start()`. A `transcribeUtterance` call
    /// captures this at entry and re-checks before mutating state —
    /// drops the result if the user started a new recording mid-flight.
    /// Without this, a late-arriving whisper result from recording N
    /// appends to recording N+1's segments (user reported seeing the
    /// previous conversation's text in a fresh recording).
    private var epoch: Int = 0

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
        self.epoch &+= 1
        liveLog.log("LiveTranscriber.start lang=\(language, privacy: .public) chunk=\(self.chunkSeconds, privacy: .public)s window=\(self.windowSeconds, privacy: .public)s useVAD=\(self.useVAD, privacy: .public) epoch=\(self.epoch, privacy: .public)")

        if useVAD {
            let det = UtteranceDetector()
            det.onUtterance = { [weak self] samples, startSec in
                self?.scheduleUtteranceTranscribe(samples: samples, startSec: startSec)
            }
            self.detector = det
            return
        }

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
        detector = nil
        lastUtteranceTask?.cancel()
        lastUtteranceTask = nil
        return fullText
    }

    /// Bump the in-flight counter and publish `isTranscribing = true`.
    /// Pair with `endTranscribe()` (typically via `defer`) so the count
    /// stays balanced even on early returns. Reads as `true` whenever
    /// at least one transcribe is running, which is what the UI's
    /// "thinking" indicator actually wants.
    ///
    /// Exposed as `internal` (not `private`) so the unit tests can
    /// drive overlapping-transcribe scenarios deterministically — the
    /// natural in-flight overlap is hard to reproduce against the
    /// stub engine because cancellation collapses the simulated
    /// delay before the test can interleave a second call.
    func beginTranscribe() {
        activeTranscribeCount += 1
        if !isTranscribing { isTranscribing = true }
    }

    /// Decrement the in-flight counter and publish
    /// `isTranscribing = false` only when the count hits zero. Without
    /// this, a stale transcribe finishing while a fresh one is still
    /// running would flip the indicator off and the UI would falsely
    /// show "idle" mid-recording.
    func endTranscribe() {
        activeTranscribeCount = max(0, activeTranscribeCount - 1)
        if activeTranscribeCount == 0, isTranscribing {
            isTranscribing = false
        }
    }

    func ingest(_ samples: ArraySlice<Float>) {
        if let detector {
            detector.ingest(samples)
        } else {
            buffer.append(contentsOf: samples)
        }
    }

    func transcribeNow() async {
        if let detector {
            // End-of-recording flush: force-emit any in-progress
            // utterance (which schedules onto lastUtteranceTask), then
            // await it so the saved transcript includes the tail.
            detector.flush()
            await lastUtteranceTask?.value
            return
        }
        await runOnce()
    }

    /// Idempotent end-of-recording flush. The cumulative model doesn't
    /// have "tentative" segments to promote, but the dictation flow
    /// still calls this — keep as a no-op.
    func finalizeAllSegments() {}

    /// Attach speaker labels to live segments by matching each
    /// segment's `[startSeconds, endSeconds]` against the diarizer's
    /// running intervals. The interval with the largest temporal
    /// overlap wins.
    ///
    /// Already-labelled segments are skipped — once we've committed a
    /// speaker to a segment we keep it stable in the UI rather than
    /// re-flipping it as more intervals arrive. The diarizer-output
    /// model produces stable speaker IDs once a voice profile is seen
    /// twice, so the early match for a segment is almost always
    /// correct; the cost of keeping it stable is a marginal accuracy
    /// gain we'd otherwise get by re-evaluating.
    ///
    /// Cost: O(unlabelled_segments × intervals). At a 2 min recording
    /// with one utterance per 500 ms and one diarizer interval per
    /// 500 ms, that's 240 × 240 = 57 600 cheap arithmetic ops per
    /// call — well under 1 ms on Apple Silicon. The caching keeps
    /// the typical-tick cost proportional to the NEW utterances
    /// since the last tick (usually 1-2 segments) × all intervals.
    func applySpeakerLabels(_ intervals: [(start: Double, end: Double, speaker: String)]) {
        guard !intervals.isEmpty, !segments.isEmpty else { return }
        var copy = segments
        var changed = false
        for i in 0..<copy.count {
            if copy[i].speaker != nil { continue }
            let segStart = copy[i].startSeconds
            let segEnd = copy[i].endSeconds
            var bestOverlap: Double = 0
            var bestSpeaker: String? = nil
            for iv in intervals {
                let overlap = min(segEnd, iv.end) - max(segStart, iv.start)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = iv.speaker
                }
            }
            if let bestSpeaker {
                copy[i].speaker = bestSpeaker
                changed = true
            }
        }
        if changed {
            segments = copy
        }
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

    /// VAD path: enqueue a transcribe for a complete utterance. New
    /// utterances chain on top of the previous task so whisper runs
    /// strictly serially (the engine actor enforces this anyway, but
    /// the chain also keeps the publish order stable).
    ///
    /// `epoch` is captured RIGHT HERE at schedule time — i.e. at the
    /// moment the VAD emitted the utterance, while we still know the
    /// audio belongs to the current recording. If we waited until
    /// `transcribeUtterance` actually started running (potentially
    /// after a fresh recording incremented the epoch), we'd compare
    /// the stale audio against the new recording's epoch and the
    /// guard would falsely pass.
    private func scheduleUtteranceTranscribe(samples: [Float], startSec: Double) {
        let scheduledEpoch = epoch
        let prev = lastUtteranceTask
        lastUtteranceTask = Task { @MainActor [weak self] in
            await prev?.value
            await self?.transcribeUtterance(samples: samples,
                                            startSec: startSec,
                                            scheduledEpoch: scheduledEpoch)
        }
    }

    private func transcribeUtterance(samples: [Float], startSec: Double, scheduledEpoch: Int) async {
        // Stale-result drop, applied BEFORE the diarizer feed so we
        // don't pollute the new recording's speaker intervals with
        // embeddings derived from the previous recording's audio. The
        // old placement of this guard (after whisper returned) only
        // protected the segment append; the diarizer's queue still
        // got fed for stale audio, leaking speakers across recordings.
        guard scheduledEpoch == epoch else {
            liveLog.log("LiveTranscriber utterance dropped at entry — epoch changed (scheduled=\(scheduledEpoch, privacy: .public) current=\(self.epoch, privacy: .public))")
            return
        }
        beginTranscribe()
        defer { endTranscribe() }
        // Hand the same utterance to the speaker diarizer in parallel
        // with whisper. The diarizer maintains its own pool of speaker
        // centroids; the matching back to segments happens via
        // `applySpeakerLabels` on the next $segments tick.
        let utteranceEnd = startSec + Double(samples.count) / sampleRate
        onUtteranceCaptured?(samples, startSec, utteranceEnd)
        // Pad short utterances to a minimum length with trailing silence.
        // Whisper.cpp's beam-search decoding (with our suppress_blank +
        // patience=-1 params) goes into an infinite loop on inputs much
        // shorter than the model's 30s receptive field — the model wants
        // to emit blank tokens but can't, with no patience cap. Padding
        // to 5s gives the decoder enough room to converge.
        let minSamples = Int(sampleRate * 5)
        let padded: [Float]
        if samples.count < minSamples {
            var p = samples
            p.append(contentsOf: Array(repeating: 0, count: minSamples - samples.count))
            padded = p
        } else {
            padded = samples
        }
        let startedAt = Date()
        // VAD-bounded short utterances: use the WhisperEngine.computeAudioCtx
        // formula (`audioCtx: nil`). This is the path the labelled-fixture
        // sweep validated — see WhisperEngine.swift's `params.audio_ctx` block.
        let whisperSegs = await transcription.transcribeOnceSegments(
            samples: padded, language: language, audioCtx: nil
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        liveLog.log("LiveTranscriber utterance: samples=\(samples.count) padded=\(padded.count) elapsed=\(elapsed, privacy: .public)s segments=\(whisperSegs.count) startSec=\(startSec, privacy: .public) epoch=\(scheduledEpoch, privacy: .public) currentEpoch=\(self.epoch, privacy: .public)")
        guard !whisperSegs.isEmpty else { return }

        // Second epoch check post-whisper: the entry check covered the
        // diarizer feed, but the user could still have started a new
        // recording between then and now (whisper takes seconds), in
        // which case we must drop the segment to avoid bleeding the
        // previous conversation into the fresh transcript.
        guard scheduledEpoch == self.epoch else {
            liveLog.log("LiveTranscriber utterance dropped post-whisper — epoch changed (scheduled=\(scheduledEpoch, privacy: .public) current=\(self.epoch, privacy: .public))")
            return
        }

        // VAD utterances are non-overlapping by construction, so we
        // just append — no merge dedup needed. Drop segments that
        // whisper hallucinated inside the padded silence tail (their
        // start time falls past the original audio duration).
        let originalDuration = Double(samples.count) / sampleRate
        for s in whisperSegs {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard s.start < originalDuration else { continue }
            segments.append(LiveSegment(
                id: UUID(),
                startSeconds: startSec + s.start,
                endSeconds: startSec + s.end,
                text: text,
                speaker: nil,
                stable: true
            ))
        }
        fullText = segments.map(\.text).joined(separator: " ")
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
        beginTranscribe()
        defer { endTranscribe() }

        let windowSamples = Int(windowSeconds * sampleRate)
        let windowStartIndex = max(0, total - windowSamples)
        let windowAbsoluteStart = Double(samplesDropped + windowStartIndex) / sampleRate
        let slice = Array(buffer[windowStartIndex..<total])

        let startedAt = Date()
        // Non-VAD fixed-window tick (legacy chunked live path). The slice is
        // up to `windowSeconds` (= 30s default) of audio, not a VAD-bounded
        // utterance, so the labelled-fixture sweep doesn't cover it. Opt out
        // of the audio_ctx truncation; whisper's default 1500-token ctx
        // applies.
        let whisperSegs = await transcription.transcribeOnceSegments(
            samples: slice, language: language, audioCtx: 0
        )
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
