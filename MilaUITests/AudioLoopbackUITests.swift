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

    /// English-only UI E2E. The Hebrew variant is covered by the
    /// pipeline-level unit test (LiveTranscriberPipelineE2ETests),
    /// which uses the full ivrit-ai model. This UI test uses
    /// `ggml-tiny.bin` (much faster, English-trained, useless for
    /// Hebrew) so the SwiftUI rendering path can be verified in
    /// reasonable CI time. Hebrew transcription quality is asserted
    /// at the unit level, not here.
    func test_english_two_minute_recording_progresses() throws {
        try runFixtureRecording(
            language: "en",
            langFlag: "--ui-test-recording-lang-en",
            wavPathEnvVar: "MILA_FIXTURE_WAV_PATH",
            // ggml-tiny on English: catches "auth/billing/thursday"
            // unreliably; settle for one common-vocab anchor.
            longTokens: ["roadmap", "search", "auth", "billing", "thursday", "march"],
            shortTokens: ["hi", "yes", "ok", "done", "great"],
            minFinalSegments: 8
        )
    }

    /// AGC E2E. Same harness as the loud English test, but pumps a
    /// fixture attenuated to ~-26 dBFS peak — the same signal level the
    /// real-world bug captured from a user's MacBook Pro mic with the
    /// system input volume turned down. The raw quiet signal sits below
    /// the live VAD's RMS cutoff (0.012), so without AGC the live
    /// transcript would stay empty. AGC default is ON, so this test
    /// proves the gain stage actually closes the gap end-to-end —
    /// fixture pump → AdaptiveGainController → onLiveSamples → VAD →
    /// whisper → live segments.
    ///
    /// Strictness is loosened vs the loud test: we want to know AGC
    /// recovered *enough* signal to clear the VAD cutoff, not that
    /// throughput matches the loud case exactly. AGC's soft-clip and
    /// the attack/release smoothing leave the boosted signal slightly
    /// noisier than the original, which can cost a few segments worth
    /// of whisper accuracy at the ggml-tiny budget.
    func test_english_low_volume_recovered_by_agc() throws {
        try runFixtureRecording(
            language: "en-quiet",
            langFlag: "--ui-test-recording-lang-en",
            wavPathEnvVar: "MILA_FIXTURE_WAV_QUIET_PATH",
            // Same conversation; same tokens. Don't require BOTH long
            // and short token hits — boosted-quiet signal may hit one
            // category cleanly while the other gets lost in the noise
            // floor that the soft-clip amplified along with the speech.
            longTokens: ["roadmap", "search", "auth", "billing", "thursday", "march"],
            shortTokens: ["hi", "yes", "ok", "done", "great"],
            minFinalSegments: 5,
            tokenStrictness: .anyCategory
        )
    }

    /// Negative AGC E2E. Same quiet fixture as the recovery test, but
    /// launches with `--ui-test-disable-agc` so the injection seam
    /// bypasses the gain stage. The raw signal sits below the VAD's RMS
    /// cutoff (~0.012), so the live transcript must stay empty — proves
    /// that if AGC silently stops working in a future change, the
    /// positive `test_english_low_volume_recovered_by_agc` would
    /// actually start failing rather than passing for some other reason
    /// (e.g. VAD threshold drift). Opt-in via
    /// `MILA_RUN_AGC_NEGATIVE=1` so the default UI E2E budget isn't
    /// extended by another 2-min run on every workflow.
    func test_english_low_volume_fails_without_agc() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_RUN_AGC_NEGATIVE"] == "1",
            "Set MILA_RUN_AGC_NEGATIVE=1 to run the negative AGC E2E (default off — adds ~2 min)."
        )
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_FIXTURE_E2E"] == "1",
            "Set MILA_FIXTURE_E2E=1 (via TEST_RUNNER_MILA_FIXTURE_E2E) to run."
        )
        guard let wavPath = ProcessInfo.processInfo.environment["MILA_FIXTURE_WAV_QUIET_PATH"] else {
            XCTFail("MILA_FIXTURE_WAV_QUIET_PATH not set for negative test")
            return
        }
        let app = XCUIApplication()
        var args = [
            "--uitests",
            "--ui-test-recording-lang-en",
            "--ui-test-disable-agc",
            "--ui-test-inject-fixture-wav=\(wavPath)",
        ]
        if let tinyPath = ProcessInfo.processInfo.environment["MILA_TINY_MODEL_PATH"],
           !tinyPath.isEmpty {
            args.append("--ui-test-tiny-model-path=\(tinyPath)")
        }
        app.launchArguments = args
        app.launch()

        // 90s budget — short on purpose. We're asserting *absence* of
        // segments, so the longer we wait the more likely a stray
        // whisper hallucination shows up. 90s is well past the loud
        // test's first-segment timing (~30-60s), so the quiet-no-AGC
        // case has had a fair shot.
        Thread.sleep(forTimeInterval: 90.0)
        let segments = app.descendants(matching: .any)
            .matching(identifier: "liveTranscript.segment")
            .allElementsBoundByIndex
        let segmentCount = segments.count
        snap(app: app, name: "[en-quiet-noagc] t=90s segs=\(segmentCount)")
        print("FixtureE2E[en-quiet-noagc]: segments=\(segmentCount) (expect ~0)")
        // Allow a small slack — ggml-tiny occasionally emits a single
        // hallucinated segment on near-silent input. We're proving the
        // pipeline DOESN'T meaningfully transcribe without AGC, not
        // that it produces literally zero output.
        XCTAssertLessThan(
            segmentCount, 3,
            "Quiet fixture without AGC produced \(segmentCount) segments — " +
            "either AGC is no longer required by the live pipeline, " +
            "or the VAD threshold was lowered. Either way, the AGC E2E " +
            "no longer proves what it claims."
        )
    }

    /// REGRESSION E2E for `fix/record-while-finalizing` (PR #4).
    ///
    /// The bug: after Stop, the Record button was disabled and showed
    /// "Finalizing…" from the moment the user hit Stop until ALL
    /// post-record processing (offline re-diarize subprocess, summarizer
    /// LLM call, m4a transcode, or batch enqueue) finished — tens of
    /// seconds. The user couldn't start a new recording in the meantime.
    /// `stopRecording` held `isFinalizingRecording = true` across the whole
    /// inline finalize via a blanket `defer`.
    ///
    /// The fix split finalize into Phase A (inline, holds the flag — the
    /// bounded live-pipeline drain + snapshot + live-singleton teardown)
    /// and Phase B (background, id-keyed `finalizeTasks` — the heavy
    /// live-singleton-free tail). `isFinalizingRecording` clears the moment
    /// Phase A ends, so the Record button frees up immediately and a NEW
    /// recording can run while the prior one finishes finalizing.
    ///
    /// What this test drives (all through the REAL `stopRecording` path —
    /// only the AVAudioEngine START is faked, via the
    /// `--ui-test-finalize-regression` seam in `MilaApp`):
    ///   1. Tap Record → stream the fixture → live segments appear.
    ///   2. Tap Stop → assert the Record button returns to a USABLE idle
    ///      state quickly (exists + enabled + not "Finalizing"). This is
    ///      the core regression assertion — in the buggy code the button
    ///      stayed disabled/"Finalizing" through the whole tail.
    ///   3. Tap Record AGAIN (only possible because the button is free) →
    ///      stream the fixture → live segments → Stop.
    ///   4. Open All Transcriptions and assert BOTH recordings landed with
    ///      non-empty transcripts — neither clobbered the other.
    ///
    /// Gated on `MILA_FIXTURE_E2E=1` like the sibling tests; uses the same
    /// tiny-model + fixture-WAV env wiring.
    func test_record_then_finalize_in_background_then_record_again() throws {
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
            "--ui-test-recording-lang-en",
            "--ui-test-finalize-regression",
            "--ui-test-inject-fixture-wav=\(wavPath)",
        ]
        if let tinyPath = ProcessInfo.processInfo.environment["MILA_TINY_MODEL_PATH"],
           !tinyPath.isEmpty {
            args.append("--ui-test-tiny-model-path=\(tinyPath)")
        }
        // NOTE: deliberately NOT passing --ui-test-llm-claude here. The
        // regression is about the button freeing up regardless of the heavy
        // tail; leaving the summarizer unconfigured keeps the Phase B tail
        // (which we want to overlap recording #2) free of an external CLI
        // dependency and keeps the test deterministic.
        app.launchArguments = args
        app.launch()

        // ---- Recording #1.
        let record = app.descendants(matching: .any)
            .matching(identifier: "home.record.hero").firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 30),
                      "Home Record button never appeared at launch")
        snap(app: app, name: "[finalize] t=0 home pre-record-1")
        record.tap()

        // The fixture pump + tiny-model cold load: first live segment can
        // take ~60-150s on a cold CI runner (see the throughput test).
        let firstSegment1 = app.staticTexts
            .matching(identifier: "liveTranscript.segment").firstMatch
        XCTAssertTrue(firstSegment1.waitForExistence(timeout: 180),
                      "Recording #1 produced no live segment within 180s")
        let segCount1 = app.descendants(matching: .any)
            .matching(identifier: "liveTranscript.segment")
            .allElementsBoundByIndex.count
        snap(app: app, name: "[finalize] recording-1 segs=\(segCount1)")
        print("FinalizeE2E: recording#1 segments=\(segCount1)")

        // ---- Stop #1 — the moment under test. After Phase A the button
        // must be usable again even though Phase B may still be running.
        let stop1 = app.descendants(matching: .any)
            .matching(identifier: "liveAI.stop").firstMatch
        XCTAssertTrue(stop1.waitForExistence(timeout: 10),
                      "Stop button missing during recording #1")
        stop1.tap()

        // CORE REGRESSION ASSERTION: the Record button comes back, becomes
        // ENABLED, and is NOT labelled "Finalizing…" — quickly. The Phase A
        // drain is bounded (transcribeNow + diarizer drain on a tiny
        // fixture), so 60s is generous; the buggy code would keep the
        // button disabled for the WHOLE tail (or indefinitely under a CLI
        // summarize). We poll because the Home view only re-renders the
        // Record button once `isRecording` flips back to false.
        let buttonFreed = pollUntil(timeout: 60) {
            let btn = app.descendants(matching: .any)
                .matching(identifier: "home.record.hero").firstMatch
            guard btn.exists, btn.isEnabled else { return false }
            // Belt-and-suspenders: the disabled state is the load-bearing
            // signal, but also reject the "Finalizing…" copy in case the
            // button is somehow enabled while still showing that label.
            return !btn.label.localizedCaseInsensitiveContains("Finalizing")
        }
        let homeRecord = app.descendants(matching: .any)
            .matching(identifier: "home.record.hero").firstMatch
        snap(app: app, name: "[finalize] after-stop-1 freed=\(buttonFreed) label=\(homeRecord.exists ? homeRecord.label : "<gone>")")
        print("FinalizeE2E: after-stop-1 freed=\(buttonFreed) enabled=\(homeRecord.exists ? "\(homeRecord.isEnabled)" : "gone")")
        XCTAssertTrue(buttonFreed,
                      "Record button stayed disabled/\"Finalizing\" after Stop #1 — the finalize is blocking the button (regression). It must free up after Phase A while the heavy Phase B tail runs in the background.")

        // ---- Recording #2 — only reachable because the button is free.
        homeRecord.tap()
        let firstSegment2 = app.staticTexts
            .matching(identifier: "liveTranscript.segment").firstMatch
        // After the tiny model is warm the second cold load is far faster,
        // but keep a generous budget for CI scheduling noise.
        XCTAssertTrue(firstSegment2.waitForExistence(timeout: 120),
                      "Recording #2 never started / produced no live segment within 120s — the Record button likely didn't actually start a new recording after Stop #1.")
        let segCount2 = app.descendants(matching: .any)
            .matching(identifier: "liveTranscript.segment")
            .allElementsBoundByIndex.count
        snap(app: app, name: "[finalize] recording-2 segs=\(segCount2)")
        print("FinalizeE2E: recording#2 segments=\(segCount2)")

        let stop2 = app.descendants(matching: .any)
            .matching(identifier: "liveAI.stop").firstMatch
        XCTAssertTrue(stop2.waitForExistence(timeout: 10),
                      "Stop button missing during recording #2")
        stop2.tap()

        // Wait for the second finalize's Phase A to free the button again.
        let buttonFreed2 = pollUntil(timeout: 60) {
            let btn = app.descendants(matching: .any)
                .matching(identifier: "home.record.hero").firstMatch
            return btn.exists && btn.isEnabled
        }
        XCTAssertTrue(buttonFreed2, "Record button stayed disabled after Stop #2")

        // ---- Assert BOTH recordings finalized with transcripts. Navigate
        // to All Transcriptions (the unfiled bucket) and read the rows.
        let allTranscriptions = app.descendants(matching: .any)
            .matching(identifier: "sidebar.folder.default").firstMatch
        XCTAssertTrue(allTranscriptions.waitForExistence(timeout: 10),
                      "All Transcriptions sidebar row missing")
        allTranscriptions.tap()

        // Both recordings should appear as history rows. Their previews
        // (the recording.fullText) must be non-empty — i.e. each kept its
        // own live transcript through finalization. Poll: Phase B's
        // rediarize/SRT may still be settling when we first navigate.
        // A `.accessibilityElement(children: .combine)` row folds the title +
        // transcript preview + meta into one element. On macOS that combined
        // text can surface in EITHER `.label` or `.value` depending on the
        // control type SwiftUI picks — the live-segment check above already
        // reads both for exactly this reason. Reading only `.label` (the old
        // code) missed the transcript that's plainly on screen, so the check
        // tripped even though both recordings finalized correctly.
        //
        // We also raise the bar from "label is non-empty" (which the title
        // alone satisfies) to "the row carries an actual fixture transcript
        // token" — that's what proves each recording kept its OWN live
        // transcript through the background finalize tail rather than landing
        // as an empty shell.
        let transcriptTokens = ["roadmap", "team", "search", "items", "hello"]
        func rowText(_ el: XCUIElement) -> String {
            let lbl = el.label
            let val = (el.value as? String) ?? ""
            return (lbl + " " + val).lowercased()
        }
        var rowCount = 0
        var rowsWithText = 0
        _ = pollUntil(timeout: 60) {
            let rows = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'history.row.'"))
                .allElementsBoundByIndex
            rowCount = rows.count
            rowsWithText = rows.filter { el in
                let text = rowText(el)
                return transcriptTokens.contains { text.contains($0) }
            }.count
            return rowCount >= 2 && rowsWithText >= 2
        }
        snap(app: app, name: "[finalize] all-transcriptions rows=\(rowCount) withText=\(rowsWithText)")
        print("FinalizeE2E: history rows=\(rowCount) withText=\(rowsWithText)")
        if rowCount < 2 || rowsWithText < 2 {
            print("FinalizeE2E: ===A11Y TREE AT FAILURE===")
            print(app.debugDescription)
            print("FinalizeE2E: ===A11Y TREE END===")
        }
        XCTAssertGreaterThanOrEqual(
            rowCount, 2,
            "Expected BOTH recordings in All Transcriptions, found \(rowCount). One recording clobbered the other (the id-keyed finalize-tail ownership regressed).")

        // Each recording must carry a transcript. Read the live segments we
        // observed during each recording as the floor (both were > 0) and
        // confirm the persisted rows aren't empty shells.
        XCTAssertGreaterThan(segCount1, 0, "Recording #1 captured no live segments")
        XCTAssertGreaterThan(segCount2, 0, "Recording #2 captured no live segments")
        XCTAssertGreaterThanOrEqual(
            rowsWithText, 2,
            "Both history rows must carry a transcript; only \(rowsWithText) of \(rowCount) carried a fixture transcript token.")
    }

    /// Poll `condition` every 0.5s until it returns true or `timeout`
    /// elapses. Returns the last evaluation. Used instead of
    /// `waitForExistence` where the thing we're waiting on is a *state*
    /// (button enabled / row count) rather than a single element's
    /// existence.
    private func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    // MARK: - Driver

    private enum TokenStrictness {
        /// Both `longTokens` and `shortTokens` must each surface ≥ 2 hits
        /// in the live transcript (the loud-fixture default).
        case bothCategories
        /// Across the union of all tokens, ≥ 2 must surface. Loosened
        /// for the quiet/AGC case where boosted-noise eats some
        /// short-utterance accuracy.
        case anyCategory
    }

    private func runFixtureRecording(
        language: String,
        langFlag: String,
        wavPathEnvVar: String,
        longTokens: [String],
        shortTokens: [String],
        minFinalSegments: Int,
        tokenStrictness: TokenStrictness = .bothCategories
    ) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_FIXTURE_E2E"] == "1",
            "Set MILA_FIXTURE_E2E=1 (via TEST_RUNNER_MILA_FIXTURE_E2E in xcodebuild env) to run."
        )
        guard let wavPath = ProcessInfo.processInfo.environment[wavPathEnvVar] else {
            XCTFail("\(wavPathEnvVar) not set — workflow must point to the generated fixture WAV")
            return
        }

        let app = XCUIApplication()
        var args = [
            "--uitests",
            langFlag,
            "--ui-test-inject-fixture-wav=\(wavPath)",
        ]
        // Use the small ggml-tiny.bin model in CI — full whisper-large
        // cold-load + transcribe is 60-200s per call, which doesn't
        // fit the UI test budget.
        if let tinyPath = ProcessInfo.processInfo.environment["MILA_TINY_MODEL_PATH"],
           !tinyPath.isEmpty {
            args.append("--ui-test-tiny-model-path=\(tinyPath)")
        }
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
        // Dump the entire accessibility tree so we can see what XCUITest
        // actually sees. Truncated in CI logs but still gives us the
        // shape we need.
        print("FixtureE2E[\(language)]: ===A11Y TREE BEGIN===")
        print(app.debugDescription)
        print("FixtureE2E[\(language)]: ===A11Y TREE END===")

        // Wait for the first VAD-emitted segment. CI macos-26 runners
        // have no fast GPU, so whisper's first call cold-loads the
        // 1.5GB model + Metal warmup + first transcribe ~60-90s.
        // Subsequent calls are 20-30s each. Generous timeout.
        let firstSegment = app.staticTexts.matching(identifier: "liveTranscript.segment").firstMatch
        let appeared = firstSegment.waitForExistence(timeout: 150)
        snap(app: app, name: "[\(language)] after first-segment wait (appeared=\(appeared))")
        if !appeared {
            // Dump the a11y tree AT FAILURE so we can see what identifiers
            // actually exist when the test gives up.
            print("FixtureE2E[\(language)]: ===A11Y TREE AT FAILURE===")
            print(app.debugDescription)
            print("FixtureE2E[\(language)]: ===A11Y TREE END===")
        }
        XCTAssertTrue(appeared,
                      "[\(language)] No live segment after 150s — see a11y tree dump above")

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
            finalCount, minFinalSegments,
            "[\(language)] Final segment count \(finalCount) below minimum \(minFinalSegments) across 120s of fixture"
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
        let foundShort = shortTokens.filter { transcript.contains($0.lowercased()) }
        switch tokenStrictness {
        case .bothCategories:
            XCTAssertGreaterThanOrEqual(
                foundLong.count, 2,
                "[\(language)] long-utterance tokens missing (\(foundLong) of \(longTokens))"
            )
            XCTAssertGreaterThanOrEqual(
                foundShort.count, 2,
                "[\(language)] short-utterance tokens missing (\(foundShort) of \(shortTokens))"
            )
        case .anyCategory:
            let total = foundLong.count + foundShort.count
            XCTAssertGreaterThanOrEqual(
                total, 2,
                "[\(language)] fewer than 2 fixture tokens surfaced across either category " +
                "(long=\(foundLong) short=\(foundShort)). AGC didn't recover enough signal."
            )
        }

        // Speaker labels: the live diarizer should have produced
        // intervals matched onto segments by now. Informational by
        // default — the live diarizer needs the bundled python runtime
        // PLUS a runtime-installed torch wheel (~62 MB download +
        // install + ad-hoc sign), and on a fresh CI runner that
        // bootstrap doesn't complete inside the 2-min test budget. The
        // pipeline-level unit test (LiveTranscriberPipelineE2ETests)
        // already exercises the live-transcribe path with the real
        // engine; speaker-label correctness is covered there + by the
        // dedicated SpeakerPoolTests. Set MILA_REQUIRE_SPEAKER_LABELS=1
        // (via TEST_RUNNER_MILA_REQUIRE_SPEAKER_LABELS) to enforce
        // the assertion, e.g. on a runner where torch is pre-cached.
        let speakerHits = segments.filter { el in
            let txt = (el.label.isEmpty ? (el.value as? String) ?? "" : el.label).lowercased()
            return txt.contains("speaker")
        }
        let requireSpeakers = ProcessInfo.processInfo
            .environment["MILA_REQUIRE_SPEAKER_LABELS"] == "1"
        print("FixtureE2E[\(language)]: speaker-hits=\(speakerHits.count)/\(segments.count) require=\(requireSpeakers)")
        if requireSpeakers {
            XCTAssertGreaterThan(
                speakerHits.count, 0,
                "[\(language)] No segment carries a speaker label. Diarizer didn't feed the segments."
            )
        }

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
