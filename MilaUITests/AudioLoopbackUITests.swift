import XCTest

/// End-to-end CI test that drives Mila through a real 2-minute
/// recording without depending on a virtual audio device. The
/// fixture-injection seam in `MilaApp.injectFixtureWavIfRequested()`
/// pumps a known WAV at 16kHz real-time into `session.onLiveSamples`,
/// so the full pipeline (VAD → whisper → diarizer → LiveAISession)
/// runs exactly as on a real recording — minus AVAudioEngine + mic.
///
/// Coverage per language run:
///   * Transcribe: segments appear and grow monotonically
///   * Speaker labels: live diarizer attaches SPEAKER_NN to segments
///   * LLM summary: when --ui-test-llm-claude=<path> is set, the
///     `liveAI.summary` element populates within the 2-min window
///   * Snapshots every 10s are attached to the xcresult
///
/// Gated on env `MILA_FIXTURE_E2E=1` (delivered via TEST_RUNNER_… so
/// the env var actually reaches the XCTest runner — plain shell envs
/// don't propagate).
final class AudioLoopbackUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_english_two_minute_recording_progresses() throws {
        try runFixtureRecording(
            language: "en",
            langFlag: "--ui-test-recording-lang-en",
            longTokens: ["search", "auth", "billing", "thursday"],
            shortTokens: ["hi", "yes", "ok", "done", "great"]
        )
    }

    func test_hebrew_two_minute_recording_progresses() throws {
        try runFixtureRecording(
            language: "he",
            langFlag: "--ui-test-recording-lang-he",
            longTokens: ["חיפוש", "מערכת", "חמישי"],
            shortTokens: ["היי", "כן", "בסדר", "סיימנו", "מצוין"]
        )
    }

    // MARK: - Driver

    private func runFixtureRecording(
        language: String,
        langFlag: String,
        longTokens: [String],
        shortTokens: [String]
    ) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_FIXTURE_E2E"] == "1",
            "Set MILA_FIXTURE_E2E=1 (via TEST_RUNNER_MILA_FIXTURE_E2E in xcodebuild env) to run."
        )
        guard let wavPath = ProcessInfo.processInfo.environment["MILA_FIXTURE_WAV_PATH"] else {
            XCTFail("MILA_FIXTURE_WAV_PATH not set — workflow must point to the generated fixture WAV")
            return
        }

        let app = XCUIApplication()
        var args = [
            "--uitests",
            langFlag,
            "--ui-test-inject-fixture-wav=\(wavPath)",
        ]
        // When the workflow has installed a Claude CLI, point Mila at
        // it so the LLM summary path runs end-to-end. When not, the
        // summary check is downgraded to a soft log.
        if let claudePath = ProcessInfo.processInfo.environment["MILA_CLAUDE_PATH"],
           !claudePath.isEmpty {
            args.append("--ui-test-llm-claude=\(claudePath)")
        }
        app.launchArguments = args
        app.launch()

        // Snapshot the launch state so we can see whether
        // LiveAIRecordingView is rendering at all when the test
        // starts (vs Home / blank screen).
        Thread.sleep(forTimeInterval: 5.0)
        snap(app: app, name: "[\(language)] t=5s post-launch")
        let containerVisible = app.descendants(matching: .any)
            .matching(identifier: "liveTranscript.container").firstMatch.exists
        let listeningVisible = app.descendants(matching: .any)
            .matching(identifier: "liveTranscript.listening").firstMatch.exists
        print("FixtureE2E[\(language)]: post-launch container=\(containerVisible) listening=\(listeningVisible)")

        // Wait for the first VAD-emitted segment. CI macos-26 runners
        // have no fast GPU, so whisper's first call cold-loads the
        // 1.5GB model + Metal warmup + first transcribe ~60-90s.
        // Subsequent calls are 20-30s each. Generous timeout.
        let firstSegment = app.staticTexts.matching(identifier: "liveTranscript.segment").firstMatch
        let appeared = firstSegment.waitForExistence(timeout: 150)
        snap(app: app, name: "[\(language)] after first-segment wait (appeared=\(appeared))")
        XCTAssertTrue(appeared,
                      "[\(language)] No live segment after 150s — see post-launch snapshot for whether the view rendered at all")

        // 12 snapshots × 10s = 120s of recording. Track segment counts
        // and screenshot each.
        var counts: [(t: Int, count: Int)] = []
        for snapshotIdx in 1...12 {
            Thread.sleep(forTimeInterval: 10.0)
            let count = app.descendants(matching: .any)
                .matching(identifier: "liveTranscript.segment")
                .allElementsBoundByIndex
                .count
            counts.append((t: snapshotIdx * 10, count: count))
            snap(app: app, name: "[\(language)] t=\(snapshotIdx * 10)s segs=\(count)")
            print("FixtureE2E[\(language)]: t=\(snapshotIdx * 10)s segments=\(count)")
        }

        // Monotonic non-decreasing
        for i in 1..<counts.count {
            XCTAssertGreaterThanOrEqual(
                counts[i].count, counts[i - 1].count,
                "[\(language)] segment count went DOWN \(counts[i-1].count)→\(counts[i].count)"
            )
        }

        // No 30s window with zero new segments.
        for i in 3..<counts.count {
            XCTAssertGreaterThan(
                counts[i].count, counts[i - 3].count,
                "[\(language)] 30s window t=\(counts[i-3].t)..\(counts[i].t) had no new segments (stuck at \(counts[i-3].count)). VAD probably stuck or pump stopped."
            )
        }

        let finalCount = counts.last?.count ?? 0
        XCTAssertGreaterThanOrEqual(
            finalCount, 8,
            "[\(language)] Final segment count \(finalCount) too low across 120s of fixture"
        )

        // Content check: language-specific tokens must appear.
        let segments = app.descendants(matching: .any)
            .matching(identifier: "liveTranscript.segment")
            .allElementsBoundByIndex
        let transcript = segments
            .compactMap { $0.label.isEmpty ? $0.value as? String : $0.label }
            .joined(separator: " ")
            .lowercased()
        print("FixtureE2E[\(language)]: ===TRANSCRIPT===\n\(transcript)\n===END===")
        let foundLong = longTokens.filter { transcript.contains($0.lowercased()) }
        XCTAssertGreaterThanOrEqual(
            foundLong.count, 2,
            "[\(language)] long-utterance tokens missing (\(foundLong) of \(longTokens))"
        )
        let foundShort = shortTokens.filter { transcript.contains($0.lowercased()) }
        XCTAssertGreaterThanOrEqual(
            foundShort.count, 2,
            "[\(language)] short-utterance tokens missing (\(foundShort) of \(shortTokens))"
        )

        // Speaker labels: the live diarizer should have produced
        // intervals matched onto segments by now. We assert that at
        // least ONE segment carries a SPEAKER_NN prefix (visible in
        // its accessibility label via `friendlySpeakerLabel`).
        let speakerHits = segments.filter { el in
            let txt = (el.label.isEmpty ? (el.value as? String) ?? "" : el.label).lowercased()
            return txt.contains("speaker")
        }
        XCTAssertGreaterThan(
            speakerHits.count, 0,
            "[\(language)] No segment carries a speaker label. Diarizer didn't feed the segments."
        )

        // LLM summary check — soft unless --ui-test-llm-claude was
        // passed (i.e. the workflow installed a CLI + key).
        let summary = app.staticTexts.matching(identifier: "liveAI.summary").firstMatch
        if let claudePath = ProcessInfo.processInfo.environment["MILA_CLAUDE_PATH"],
           !claudePath.isEmpty {
            XCTAssertTrue(summary.waitForExistence(timeout: 30),
                          "[\(language)] liveAI.summary element never rendered despite CLI configured")
            let body = summary.label
            print("FixtureE2E[\(language)]: summary len=\(body.count) body=\(body.prefix(200))")
            XCTAssertFalse(body.isEmpty,
                           "[\(language)] LLM summary is empty after 2 min — session didn't run or returned nothing")
        } else {
            if summary.exists {
                print("FixtureE2E[\(language)]: summary len=\(summary.label.count) (no CLI configured — informational only)")
            }
        }
    }

    private func snap(app: XCUIApplication, name: String) {
        let shot = app.windows.firstMatch.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
