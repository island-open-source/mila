import XCTest
import TranscriptionCore
@testable import Mila

/// Tests for the live transcriber. Live mode keeps whisper's per-segment
/// timing through the loop so we can render one line per utterance (and,
/// later, match speakers to segments by time). The merge logic is the
/// core invariant — exercised here both end-to-end (via the public
/// `transcribeNow()` helper with canned whisper output) and via the
/// pure `merge(...)` helper.
@MainActor
final class LiveTranscriberTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var transcriber: LiveTranscriber!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "LiveTranscriberTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        try TestSupport.installFakeModel(into: manager)
        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "LiveTranscriberTests.diarization")!),
            engine: stub
        )
        transcriber = LiveTranscriber(transcription: service)
        transcriber.chunkSeconds = 5
        transcriber.windowSeconds = 10
    }

    override func tearDown() async throws {
        transcriber = nil
        service = nil
        stub = nil
        manager = nil
        store = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    // MARK: - End-to-end segment accumulation

    func test_transcribeNow_populates_segments_and_fullText() async {
        let samples = Array(repeating: Float(0.3), count: 32_000)
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(samples))
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "hello")])
        await transcriber.transcribeNow()
        XCTAssertEqual(transcriber.segments.map(\.text), ["hello"])
        XCTAssertEqual(transcriber.fullText, "hello")
        _ = transcriber.stop()
    }

    func test_successive_ticks_dedup_overlap_by_time() async {
        // Two ticks. Each whisper call sees the window starting at the
        // same absolute time (0s in this test because the buffer is
        // small enough to fit in one window). Tick 1: ["hello world"
        // 0–1s]. Tick 2: ["hello world how are you" 0–2s]. The second
        // tick's segment has the same start time as the first, so the
        // merge replaces the existing entry with the longer text.
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "hello world")],
            [TranscriptSegment(start: 0, end: 2, text: "hello world how are you")]
        ])
        let samples = Array(repeating: Float(0.3), count: 32_000)
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(samples))
        await transcriber.transcribeNow()
        XCTAssertEqual(transcriber.segments.map(\.text), ["hello world"])
        transcriber.ingest(ArraySlice(samples))
        await transcriber.transcribeNow()
        XCTAssertEqual(transcriber.segments.map(\.text), ["hello world how are you"])
        _ = transcriber.stop()
    }

    func test_new_segment_past_cutoff_is_appended_as_a_new_line() async {
        // Tick 1: one segment 0–1s. Tick 2: two segments — same 0–1s
        // (already have it, skip) and 2–3s (new, append).
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "alpha")],
            [
                TranscriptSegment(start: 0, end: 1, text: "alpha"),
                TranscriptSegment(start: 2, end: 3, text: "beta")
            ]
        ])
        let samples = Array(repeating: Float(0.3), count: 32_000)
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(samples))
        await transcriber.transcribeNow()
        transcriber.ingest(ArraySlice(samples))
        await transcriber.transcribeNow()
        XCTAssertEqual(transcriber.segments.map(\.text), ["alpha", "beta"])
        _ = transcriber.stop()
    }

    /// VAD-path test: each utterance transcribe must fan out to the
    /// `onUtteranceCaptured` callback so the live speaker diarizer
    /// actually receives samples to embed. Earlier the daemon was
    /// spawned + "ready" but no caller ever fed it, so speaker labels
    /// never appeared. This is the seam that catches that regression.
    func test_VAD_utterance_fires_onUtteranceCaptured_with_same_samples() async {
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "hi")])

        var capturedSamples: [Float] = []
        var capturedStart: Double = -1
        var capturedEnd: Double = -1
        let expectation = XCTestExpectation(description: "onUtteranceCaptured fired")

        transcriber.useVAD = true
        transcriber.onUtteranceCaptured = { samples, start, end in
            capturedSamples = samples
            capturedStart = start
            capturedEnd = end
            expectation.fulfill()
        }
        transcriber.start(language: "en")

        // Synthesize 1.2s of speech-energy audio (well above the VAD
        // threshold) followed by 1s of silence so the detector emits.
        let speech = Array(repeating: Float(0.05), count: 16_000 * 12 / 10)
        let silence = Array(repeating: Float(0.0), count: 16_000)
        transcriber.ingest(ArraySlice(speech + silence))

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertGreaterThan(capturedSamples.count, 0,
                             "callback fired with empty samples — would feed the diarizer nothing")
        XCTAssertGreaterThanOrEqual(capturedStart, 0)
        XCTAssertGreaterThan(capturedEnd, capturedStart,
                             "end (\(capturedEnd)) should be after start (\(capturedStart))")
        _ = transcriber.stop()
    }

    func test_formattedTranscript_uses_timestamps_one_line_per_segment() async {
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "first"),
            TranscriptSegment(start: 65, end: 67, text: "second")
        ])
        let samples = Array(repeating: Float(0.3), count: 32_000)
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(samples))
        await transcriber.transcribeNow()
        // Two segments, each rendered with its [mm:ss] prefix on its
        // own line — that's what the LLM tick sees.
        XCTAssertEqual(transcriber.formattedTranscript,
                       "[00:00] first\n[01:05] second")
        _ = transcriber.stop()
    }

    func test_stop_returns_accumulated_text() async {
        let samples = Array(repeating: Float(0.3), count: 32_000)
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(samples))
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "final")])
        await transcriber.transcribeNow()
        XCTAssertEqual(transcriber.stop(), "final")
    }

    // MARK: - Pure merge helper

    func test_merge_appends_segment_strictly_past_last_end() {
        var existing: [LiveSegment] = [
            LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 1, text: "a", speaker: nil, stable: true)
        ]
        LiveTranscriber.merge(
            incoming: [LiveSegment(id: UUID(), startSeconds: 2, endSeconds: 3, text: "b", speaker: nil, stable: true)],
            into: &existing
        )
        XCTAssertEqual(existing.map(\.text), ["a", "b"])
    }

    func test_merge_replaces_last_when_same_start_extended() {
        var existing: [LiveSegment] = [
            LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 1, text: "hello", speaker: nil, stable: true)
        ]
        LiveTranscriber.merge(
            incoming: [LiveSegment(id: UUID(), startSeconds: 0.1, endSeconds: 2, text: "hello world", speaker: nil, stable: true)],
            into: &existing
        )
        // Same utterance + longer end → replace, not append.
        XCTAssertEqual(existing.count, 1)
        XCTAssertEqual(existing.first?.text, "hello world")
        XCTAssertEqual(existing.first?.endSeconds, 2)
    }

    func test_merge_skips_segment_fully_inside_existing_range() {
        var existing: [LiveSegment] = [
            LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 5, text: "old", speaker: nil, stable: true)
        ]
        // Incoming starts in the middle of `old`, doesn't extend it,
        // and isn't the same utterance — skip.
        LiveTranscriber.merge(
            incoming: [LiveSegment(id: UUID(), startSeconds: 2, endSeconds: 3, text: "fragment", speaker: nil, stable: true)],
            into: &existing
        )
        XCTAssertEqual(existing.map(\.text), ["old"])
    }

    func test_merge_empty_existing_appends_everything() {
        var existing: [LiveSegment] = []
        let incoming: [LiveSegment] = [
            LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 1, text: "a", speaker: nil, stable: true),
            LiveSegment(id: UUID(), startSeconds: 1.5, endSeconds: 2, text: "b", speaker: nil, stable: true)
        ]
        LiveTranscriber.merge(incoming: incoming, into: &existing)
        XCTAssertEqual(existing.map(\.text), ["a", "b"])
    }

    // MARK: - Buffer trim invariant

    func test_buffer_is_bounded_during_long_recordings() async {
        // Feed many ticks worth of samples (15× a full window) and
        // confirm the buffer stays bounded — the trim should keep it
        // around `windowSeconds` + a half-chunk of headroom, regardless
        // of total ingested length. Bugbot caught the unbounded
        // accumulation in PR #20.
        transcriber.start(language: "en")
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "ok")])
        let perTick = Int(transcriber.chunkSeconds * 16_000)  // 5s at 16kHz
        for _ in 0..<15 {
            transcriber.ingest(ArraySlice(Array(repeating: Float(0.3), count: perTick)))
            await transcriber.transcribeNow()
        }
        // chunkSeconds=5, windowSeconds=10 in setUp → keep ≤ 10s + 2.5s
        // headroom = 12.5s = 200_000 samples.
        let bufferCount = await Self.peekBuffer(transcriber)
        XCTAssertLessThanOrEqual(bufferCount, 200_000,
                                 "Buffer should be trimmed — got \(bufferCount) samples")
        _ = transcriber.stop()
    }

    /// Reflective peek at the private `buffer` count. Adding a real
    /// accessor on LiveTranscriber just for tests would be API bloat;
    /// the invariant the test cares about is "size stays bounded."
    @MainActor
    private static func peekBuffer(_ t: LiveTranscriber) async -> Int {
        let mirror = Mirror(reflecting: t)
        for child in mirror.children {
            if child.label == "buffer", let arr = child.value as? [Float] {
                return arr.count
            }
        }
        return -1
    }

    func test_segment_timestamps_stay_absolute_after_buffer_trim() async {
        // After enough ticks for the trim to kick in, the absolute
        // start time of NEW segments should reflect their real
        // recording-time position, not their position inside the
        // trimmed buffer. We feed 20 ticks (well past the trim
        // threshold) of identical-length audio with a canned segment
        // starting at the END of each window; assert the LAST appended
        // segment's start time is ~ recording-time, not ~0.
        transcriber.start(language: "en")
        let chunkSamples = Int(transcriber.chunkSeconds * 16_000)
        // Canned segment placed at the window's tail so each tick
        // produces strictly-new content (no merge with previous).
        await stub.setDefaultCanned([
            TranscriptSegment(start: 9, end: 10, text: "tail")
        ])
        for _ in 0..<20 {
            transcriber.ingest(ArraySlice(Array(repeating: Float(0.3), count: chunkSamples)))
            await transcriber.transcribeNow()
        }
        guard let last = transcriber.segments.last else {
            XCTFail("No segments accumulated")
            return
        }
        // 20 ticks × 5s/tick = 100s; the last window ends at 100s, so
        // its tail-canned segment starts at 99s (well past anything
        // a non-offset trimmed buffer would produce).
        XCTAssertGreaterThan(last.startSeconds, 80,
                             "Absolute timestamps regressed after trim — last.startSeconds=\(last.startSeconds)")
        _ = transcriber.stop()
    }

    // MARK: - Legacy API shape (no-op in segment model)

    /// REGRESSION (PR #32 follow-up — Bugbot Finding #2, "stale
    /// transcribeUtterance.defer flips isTranscribing to false during
    /// a new recording's transcribe"):
    ///
    /// When two transcribes overlap in time — a stale one finishing
    /// while a fresh one is mid-whisper — the older defer must not
    /// flip the UI's "thinking" indicator off. With the previous
    /// `isTranscribing = true; defer { isTranscribing = false }`
    /// pattern, the stale defer would race the active transcribe and
    /// the indicator would go dark spuriously. The counter-backed
    /// `beginTranscribe`/`endTranscribe` pair fixes that: the bool
    /// only flips false when the count reaches zero.
    ///
    /// Test strategy: drive two concurrent VAD-path transcribes by
    /// starting recording A with a slow whisper, then calling start()
    /// again (new epoch) and feeding B before A's whisper returns.
    /// Both transcribes will be in flight at once; the stale A's
    /// `defer { endTranscribe() }` must not flip `isTranscribing`
    /// false while B is still running.
    func test_isTranscribing_stays_true_when_stale_transcribe_overlaps_fresh_one() {
        // Direct unit test of the counter-backed indicator. Driving
        // the actual overlap through the public API is hard because
        // the stub engine collapses its simulated delay on Task
        // cancellation, so a stale transcribe always completes
        // before a fresh one can start. The counter logic is the
        // load-bearing piece — it's what guarantees a stale defer
        // can't flip the indicator off while a fresh transcribe is
        // running — so we drive begin / end directly.
        XCTAssertFalse(transcriber.isTranscribing)

        // -- "Stale" transcribe A begins --
        transcriber.beginTranscribe()
        XCTAssertTrue(transcriber.isTranscribing,
                      "First begin should publish isTranscribing = true")

        // -- "Fresh" transcribe B begins WHILE A is still running --
        transcriber.beginTranscribe()
        XCTAssertTrue(transcriber.isTranscribing,
                      "Second begin should keep isTranscribing = true (count=2)")

        // -- A's stale defer fires (the bug-shape: would flip the
        //    indicator off under the old `defer { isTranscribing = false }`) --
        transcriber.endTranscribe()
        XCTAssertTrue(transcriber.isTranscribing,
                      "Stale defer must NOT flip indicator off while a fresh transcribe is in flight — this is the regression Finding #2 caught")

        // -- B finishes --
        transcriber.endTranscribe()
        XCTAssertFalse(transcriber.isTranscribing,
                       "Once all transcribes have ended, indicator should clear")
    }

    /// Belt-and-suspenders: an extra `endTranscribe` (from a stale
    /// task somehow firing its defer twice, or a count drift) must
    /// not push the counter negative or stick the indicator on.
    func test_endTranscribe_does_not_go_negative() {
        XCTAssertFalse(transcriber.isTranscribing)
        transcriber.endTranscribe()
        XCTAssertFalse(transcriber.isTranscribing)
        transcriber.beginTranscribe()
        transcriber.endTranscribe()
        transcriber.endTranscribe()  // extra — must be a no-op
        XCTAssertFalse(transcriber.isTranscribing)
        // A fresh begin after the spurious end must still flip true.
        transcriber.beginTranscribe()
        XCTAssertTrue(transcriber.isTranscribing)
        transcriber.endTranscribe()
        XCTAssertFalse(transcriber.isTranscribing)
    }

    func test_applySpeakerLabels_is_a_noop_in_live_mode() async {
        let samples = Array(repeating: Float(0.3), count: 32_000)
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(samples))
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "hi")])
        await transcriber.transcribeNow()
        let before = transcriber.segments.map(\.text)
        transcriber.applySpeakerLabels([(start: 0, end: 5, speaker: "SPEAKER_00")])
        XCTAssertEqual(transcriber.segments.map(\.text), before)
        _ = transcriber.stop()
    }
}
