import XCTest
import TranscriptionCore
@testable import Mila

/// Validate `LiveTranscriber.applySpeakerLabels` — correctness AND that
/// it stays fast enough to call every tick on a 2-minute recording's
/// worth of segments without dragging the UI behind the audio.
@MainActor
final class LiveTranscriberSpeakerLabelTests: XCTestCase {

    private func makeTranscriber() -> LiveTranscriber {
        // The TranscriptionService init needs a store / model manager /
        // diarization settings. We never call transcribe in these tests
        // (only seedForTesting + applySpeakerLabels), so the engine is
        // a stub and the dirs are throwaway temp paths.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTranscriberSpeakerLabelTests-\(UUID().uuidString)")
        let store = RecordingStore(rootDirectory: tempRoot)
        let models = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        let service = TranscriptionService(
            store: store,
            modelManager: models,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "LiveTranscriberSpeakerLabelTests")!
            ),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "LiveTranscriberSpeakerLabelTests"),
            engine: StubWhisperEngine()
        )
        return LiveTranscriber(transcription: service)
    }

    private func seg(_ start: Double, _ end: Double, _ text: String = "") -> LiveSegment {
        LiveSegment(id: UUID(),
                    startSeconds: start, endSeconds: end,
                    text: text, speaker: nil, stable: true)
    }

    // MARK: - Correctness

    func test_label_picks_interval_with_max_overlap() {
        let t = makeTranscriber()
        t.seedForTesting([seg(10.0, 12.0, "hello")])

        // Two candidate intervals. SPEAKER_01 has 1.5s overlap with the
        // segment; SPEAKER_00 has 0.5s. SPEAKER_01 must win.
        t.applySpeakerLabels([
            (start: 9.5, end: 10.5, speaker: "SPEAKER_00"),
            (start: 10.5, end: 12.5, speaker: "SPEAKER_01"),
        ])
        XCTAssertEqual(t.segments.first?.speaker, "SPEAKER_01")
    }

    func test_already_labelled_segment_is_preserved() {
        let t = makeTranscriber()
        var pre = seg(10.0, 12.0)
        pre.speaker = "SPEAKER_00"
        t.seedForTesting([pre])

        // Even if a NEW interval would now claim larger overlap, we
        // keep the original label so the UI doesn't flicker.
        t.applySpeakerLabels([
            (start: 10.0, end: 12.0, speaker: "SPEAKER_99"),
        ])
        XCTAssertEqual(t.segments.first?.speaker, "SPEAKER_00")
    }

    func test_segment_without_any_overlap_gets_no_label() {
        let t = makeTranscriber()
        t.seedForTesting([seg(10.0, 12.0)])
        // Intervals far from the segment — no overlap.
        t.applySpeakerLabels([
            (start: 0.0, end: 1.0, speaker: "SPEAKER_00"),
            (start: 100.0, end: 101.0, speaker: "SPEAKER_01"),
        ])
        XCTAssertNil(t.segments.first?.speaker,
                     "No overlap means no label — leaving nil is correct so the UI shows no prefix.")
    }

    func test_labels_apply_across_many_segments() {
        let t = makeTranscriber()
        // 4 segments, alternating speakers in the underlying intervals.
        t.seedForTesting([
            seg(0.0, 1.0),
            seg(2.0, 3.0),
            seg(4.0, 5.0),
            seg(6.0, 7.0),
        ])
        t.applySpeakerLabels([
            (start: 0.0, end: 1.5, speaker: "A"),
            (start: 1.5, end: 3.5, speaker: "B"),
            (start: 3.5, end: 5.5, speaker: "A"),
            (start: 5.5, end: 7.5, speaker: "B"),
        ])
        XCTAssertEqual(t.segments.map { $0.speaker }, ["A", "B", "A", "B"])
    }

    // MARK: - Performance

    /// Simulate a 2-minute recording's worth of speaker labelling. The
    /// observer in `MilaApp` calls `applySpeakerLabels` every time
    /// segments changes — roughly once per emitted utterance. Across
    /// 120 s with one utterance every ~500 ms we get ~240 calls; we
    /// stress-test 50 of them at the END of the recording (worst-case
    /// segment count) to verify we don't fall behind the audio.
    func test_apply_speaker_labels_is_fast_at_two_minute_scale() {
        let t = makeTranscriber()

        // 240 segments simulating 2 min × 1 utterance/500ms.
        // Each is 400ms long with a 100ms gap.
        var segs: [LiveSegment] = []
        var time: Double = 0
        for _ in 0..<240 {
            segs.append(seg(time, time + 0.4))
            time += 0.5
        }
        t.seedForTesting(segs)

        // 240 diarizer intervals simulating one 500ms interval per
        // utterance, alternating speakers.
        var intervals: [(start: Double, end: Double, speaker: String)] = []
        for i in 0..<240 {
            let start = Double(i) * 0.5
            intervals.append((start: start,
                              end: start + 0.5,
                              speaker: i % 2 == 0 ? "SPEAKER_00" : "SPEAKER_01"))
        }

        // First call: labels all 240 unlabelled segments. Measure ONLY
        // this — subsequent calls hit the early-skip path for already-
        // labelled segments and are essentially free.
        let firstCallStart = Date()
        t.applySpeakerLabels(intervals)
        let firstCallElapsed = Date().timeIntervalSince(firstCallStart)

        // Subsequent calls (49 more) — verify the caching makes them
        // near-free even at 2-min scale.
        let subsequentStart = Date()
        for _ in 0..<49 {
            t.applySpeakerLabels(intervals)
        }
        let subsequentElapsed = Date().timeIntervalSince(subsequentStart)

        // All segments should be labelled.
        XCTAssertEqual(t.segments.filter { $0.speaker != nil }.count, 240,
                       "All 240 segments should have been labelled on the first call.")

        // Budget: the first call (worst case — labels 240 segments
        // against 240 intervals = 57600 overlap checks) should be
        // well under 50ms on macos-26 CI (Apple Silicon).
        // The cached subsequent 49 calls should aggregate to <50ms.
        XCTAssertLessThan(firstCallElapsed, 0.05,
                          "First-call apply at 2-min scale took \(firstCallElapsed)s — would visibly lag the live transcript.")
        XCTAssertLessThan(subsequentElapsed, 0.05,
                          "49 cached calls took \(subsequentElapsed)s — caching isn't working.")
        print("LiveTranscriberSpeakerLabelTests: first=\(firstCallElapsed)s subsequent_49=\(subsequentElapsed)s")
    }
}
