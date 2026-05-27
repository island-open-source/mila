import XCTest

/// End-to-end audio loopback test. Drives Mila through a real
/// recording while a known WAV is played onto a virtual audio device
/// (BlackHole) that's been set as the system's default input. Catches
/// regressions in the audio capture → live transcriber wiring that
/// pure-Swift unit tests miss (any mock at `WhisperEngine` or
/// `RecordingSession.onLiveSamples` bypasses the seam where bugs
/// like "ingest never called" actually live).
///
/// Local run:
///   1. brew install blackhole-2ch switchaudio-osx
///   2. SwitchAudioSource -t input -s "BlackHole 2ch"
///   3. ./scripts/generate-audio-fixture.sh /tmp/mila-loopback-fixture.wav
///   4. afplay /tmp/mila-loopback-fixture.wav &
///   5. xcodebuild test -only-testing:MilaUITests/AudioLoopbackUITests …
///
/// In CI: `.github/workflows/audio-loopback-e2e.yml` does the above.
///
/// The test is gated on `MILA_LOOPBACK_E2E=1` so a stray local run of
/// the full UI test suite without BlackHole installed doesn't fail
/// spuriously — outside the loopback environment the test SKIPs.
final class AudioLoopbackUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_recording_produces_live_segments_within_30s() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_LOOPBACK_E2E"] == "1",
            "Set MILA_LOOPBACK_E2E=1 to run; needs BlackHole as default input + fixture playing"
        )

        let app = XCUIApplication()
        app.launchArguments = ["--uitests"]
        app.launch()

        let recordButton = app.buttons["home.record.hero"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 10),
                      "Record CTA never appeared on Home")
        recordButton.tap()

        // The CI fixture is ~60s and loops in the background. Let it
        // play for ~70s so multiple loops give the detector + whisper
        // pipeline plenty of utterances to chew on, and so we exercise
        // "works over a long period of time" — not just the first hit.
        let totalWatchSeconds: TimeInterval = 70
        let watchUntil = Date().addingTimeInterval(totalWatchSeconds)
        let firstSegment = app.staticTexts.matching(identifier: "liveTranscript.segment").firstMatch
        XCTAssertTrue(firstSegment.waitForExistence(timeout: 25),
                      "No live segment after 25s — RecordingSession.onLiveSamples likely didn't wire to LiveTranscriber.ingest")
        // Snapshot at 25s for early failures.
        snap(app: app, name: "after-first-segment")

        while Date() < watchUntil {
            Thread.sleep(forTimeInterval: 2.0)
        }
        snap(app: app, name: "after-70s")

        let segments = app.staticTexts.matching(identifier: "liveTranscript.segment").allElementsBoundByIndex
        let segmentCount = segments.count
        // The fixture has 14 short / medium / long lines with ~600ms
        // pauses between, played in a loop. Across 70 seconds the
        // detector should land at least 8 utterances on the live pane.
        // Set the floor low enough that runner-to-runner whisper
        // timing variance doesn't flake — but high enough to catch
        // a regression that misses most of the speech (the symptom
        // we're chasing).
        XCTAssertGreaterThanOrEqual(
            segmentCount, 8,
            "Only \(segmentCount) live segment(s) after 70s — VAD is dropping too much speech."
        )

        // Concatenate all segment text and check for distinctive
        // tokens. If the detector is catching the LONG sentences but
        // dropping the SHORT ones, "Hi." / "Yes." / "OK." would all
        // be missing while "search index migration" would still land.
        let transcript = segments
            .compactMap { $0.label.isEmpty ? $0.value as? String : $0.label }
            .joined(separator: " ")
            .lowercased()
        print("AudioLoopbackUITests: transcript len=\(transcript.count) segments=\(segmentCount)")
        print("AudioLoopbackUITests: ===TRANSCRIPT_START===")
        print(transcript)
        print("AudioLoopbackUITests: ===TRANSCRIPT_END===")

        // Distinctive long-utterance tokens — if these are missing,
        // whisper is failing entirely (not a VAD issue).
        let longTokens = ["search", "auth", "billing", "thursday"]
        let foundLong = longTokens.filter { transcript.contains($0) }
        XCTAssertGreaterThanOrEqual(
            foundLong.count, 2,
            "Long-utterance tokens almost absent (found \(foundLong) of \(longTokens)). Whisper itself may be failing."
        )

        // Distinctive SHORT-utterance tokens — these are the ones
        // VAD might drop if minUtteranceMs is too high. They're
        // single-word lines in the fixture: "Hi.", "Yes.", "OK.",
        // "Done.", "Great." — exactly the pattern the user reported
        // as "barely picks up… only some words".
        let shortTokens = ["hi", "yes", "ok", "done", "great"]
        let foundShort = shortTokens.filter { transcript.contains($0) }
        XCTAssertGreaterThanOrEqual(
            foundShort.count, 2,
            "Short-utterance tokens missing (found \(foundShort) of \(shortTokens)). This is the bug — single-word responses are being dropped by VAD."
        )
    }

    private func snap(app: XCUIApplication, name: String) {
        let shot = app.windows.firstMatch.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
