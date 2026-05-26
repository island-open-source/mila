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
///   4. afplay -d "BlackHole 2ch" /tmp/mila-loopback-fixture.wav &
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

        // Tap the big Record CTA on Home. The CTA's identifier is
        // `home.record.hero` (see HomeView.swift). The test is
        // intentionally tolerant about which audio source the user
        // selected — we just want some recording to start so the
        // wiring can be exercised.
        let recordButton = app.buttons["home.record.hero"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 10),
                      "Record CTA never appeared on Home")
        recordButton.tap()

        // Wait for at least one live segment to land in the pane.
        // The CI workflow starts `afplay` of the fixture ~immediately
        // before launching this test, so audio is already flowing on
        // BlackHole by the time we tap Record. 30s gives whisper
        // enough headroom on the slowest macos-26 VM.
        let segment = app.staticTexts.matching(identifier: "liveTranscript.segment").firstMatch
        let appeared = segment.waitForExistence(timeout: 30)
        if !appeared {
            let listening = app.staticTexts["liveTranscript.listening"].exists
            XCTFail("No live segment after 30s (still showing 'Listening…': \(listening)). " +
                    "This usually means RecordingSession.onLiveSamples never wired to LiveTranscriber.ingest.")
        }

        // Snapshot for the artifact uploader.
        let snap = app.screenshot()
        let att = XCTAttachment(screenshot: snap)
        att.name = "after-30s"
        att.lifetime = .keepAlways
        add(att)

        // We have at least one segment — that's the bug-catching
        // assertion. Now grab the count for the report and stop.
        let count = app.staticTexts.matching(identifier: "liveTranscript.segment").count
        print("AudioLoopbackUITests: saw \(count) live segment(s) before stop")
        XCTAssertGreaterThan(count, 0)
    }
}
