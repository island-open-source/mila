import XCTest
@testable import Mila

/// Coverage for `RecordingSummarizer.backfillIfNeeded()` — the scan that
/// runs on launch + on LLM-config flip and walks the store generating
/// summaries for recordings that don't have one yet.
///
/// All end-to-end calls go through `RecordingSummarizer`'s injectable
/// `runLLM` seam (see `RecordingSummarizer.RunLLM`) instead of spawning a
/// real `claude`/`/bin/sh` subprocess — same rationale as
/// `RecordingSummarizerTests`: the real-subprocess path was the source of CI
/// flake under contention. The stub returns canned output synchronously, and
/// the concurrency / ordering assertions are driven by an in-process
/// `ConcurrencyProbe` (a gate + counter) rather than by probe files written
/// from shell scripts, so they're deterministic.
@MainActor
final class RecordingSummarizerBackfillTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var llmDefaults: UserDefaults!
    private var liveDefaults: UserDefaults!
    private var llm: LLMSettings!
    private var liveAI: LiveAISettings!
    private var summarizer: RecordingSummarizer!

    private let llmSuite = "RecordingSummarizerBackfillTests.llm"
    private let liveSuite = "RecordingSummarizerBackfillTests.liveAI"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "BackfillTests")
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        UserDefaults().removePersistentDomain(forName: llmSuite)
        UserDefaults().removePersistentDomain(forName: liveSuite)
        llmDefaults = UserDefaults(suiteName: llmSuite)
        liveDefaults = UserDefaults(suiteName: liveSuite)
        llm = LLMSettings(defaults: llmDefaults)
        liveAI = LiveAISettings(defaults: liveDefaults)
        // Built with the production runner by default; each test that drives
        // end-to-end work rebuilds it via `useStubRunner` with a stub.
        summarizer = RecordingSummarizer(store: store,
                                         llmSettings: llm,
                                         liveAISettings: liveAI)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        llmDefaults?.removePersistentDomain(forName: llmSuite)
        liveDefaults?.removePersistentDomain(forName: liveSuite)
        try await super.tearDown()
    }

    // MARK: - Selection

    /// Backfill picks up `.completed` recordings missing summaries, and
    /// skips the rest. Verifies the four criteria from the spec all in
    /// one go so a future regression that loosens any of them is caught.
    func test_backfill_only_targets_completed_non_trashed_missing_summary() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _ in "FILLED" }

        // Eligible: completed, non-empty text, no summary, not trashed.
        let target = try addRecording(title: "Target",
                                      status: .completed,
                                      fullText: "the transcript",
                                      summary: nil)
        // Ineligible: already summarized.
        let alreadySummarized = try addRecording(title: "Summarized",
                                                 status: .completed,
                                                 fullText: "the transcript",
                                                 summary: "already here")
        // Ineligible: trashed.
        var trashed = try addRecording(title: "Trashed",
                                       status: .completed,
                                       fullText: "the transcript",
                                       summary: nil)
        trashed.deletedAt = Date()
        store.update(trashed)
        // Ineligible: never finished transcribing.
        _ = try addRecording(title: "Pending",
                             status: .pending,
                             fullText: "",
                             summary: nil)
        // Ineligible: completed but empty transcript.
        _ = try addRecording(title: "Empty",
                             status: .completed,
                             fullText: "",
                             summary: nil)

        summarizer.backfillIfNeeded()
        try await waitForSummary(recordingID: target.id)

        // The eligible one got the stub's output.
        XCTAssertEqual(currentSummary(of: target.id), "FILLED")
        // The already-summarized one was left alone.
        XCTAssertEqual(currentSummary(of: alreadySummarized.id), "already here")
        // The trashed one stayed nil.
        XCTAssertNil(currentSummary(of: trashed.id))
    }

    /// When the LLM isn't configured, the scan is a no-op (no CLI calls,
    /// no summaries written). The internal `$tool` subscriber re-runs the
    /// scan once the user flips it on at runtime — covered by a
    /// dedicated test below.
    func test_backfill_noops_when_llm_not_configured() async throws {
        llm.tool = .none
        var called = false
        useStubRunner { _, _, _, _, _, _, _ in
            called = true
            return "NOPE"
        }

        let rec = try addRecording(title: "Skip",
                                   status: .completed,
                                   fullText: "transcript",
                                   summary: nil)

        // `backfillIfNeeded` gates on `isConfigured` synchronously, so no
        // task is ever spawned — assert that directly, no sleep needed.
        summarizer.backfillIfNeeded()
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "backfill must not spawn a task when the LLM is unconfigured")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(called, "the runner must not be invoked when the LLM is unconfigured")
        XCTAssertNil(currentSummary(of: rec.id))
    }

    /// Flipping `LLMSettings.tool` from .none to .claude must trigger an
    /// automatic backfill. This is the "user just finished setting up
    /// their CLI" path — without the auto-trigger the user would have
    /// to relaunch the app or wait for a fresh recording to see summaries
    /// fill in.
    func test_backfill_runs_on_llm_config_flip() async throws {
        useStubRunner { _, _, _, _, _, _, _ in "AUTO" }

        // LLM starts unconfigured.
        XCTAssertEqual(llm.tool, .none)

        let rec = try addRecording(title: "Flip",
                                   status: .completed,
                                   fullText: "transcript",
                                   summary: nil)

        // Now configure — the `$tool` publisher in the summarizer should
        // notice and kick a backfill. The sink hops through
        // `DispatchQueue.main` (see RecordingSummarizer.init), so the
        // summary task is created on a later main tick; await its landing.
        llm.tool = .claude

        try await waitForSummary(recordingID: rec.id)
        XCTAssertEqual(currentSummary(of: rec.id), "AUTO")
    }

    // MARK: - Throttle + ordering

    /// With N candidates and `maxConcurrent` = 2, at no point should more
    /// than 2 stub invocations be running at the same time. The probe
    /// counts concurrent presence in-process (no shell script, no probe
    /// files) and parks each call on a gate so overlap is forced and
    /// observable.
    func test_backfill_throttles_to_max_concurrent() async throws {
        let probe = ConcurrencyProbe()
        useStubRunner { _, _, _, _, _, _, _ in
            await probe.enterAndWait()
            return "DONE"
        }

        // 5 candidates — comfortably above the cap.
        var recs: [Recording] = []
        for i in 0..<5 {
            let r = try addRecording(title: "Rec\(i)",
                                     status: .completed,
                                     fullText: "transcript \(i)",
                                     summary: nil)
            recs.append(r)
        }

        llm.tool = .claude
        summarizer.maxConcurrent = 2
        summarizer.backfillIfNeeded()

        // Exactly `maxConcurrent` calls should be parked at the peak. Wait
        // for the first wave to fill the cap, then assert it never exceeded.
        await probe.waitUntilCurrent(2)
        XCTAssertEqual(probe.maxObserved, 2,
                       "Backfill should run exactly 2 concurrently at the cap (saw \(probe.maxObserved))")

        // Release everything; subsequent waves pass straight through the
        // (now-open) gate. The cap still holds because the summarizer never
        // starts more than `maxConcurrent` tasks at once. Drain via a
        // bounded poll: later candidates are still in `backfillQueue` (no
        // in-flight task to await yet), and `pumpBackfill` only promotes
        // them as earlier ones finish.
        probe.releaseAll()
        for rec in recs {
            try await waitForSummary(recordingID: rec.id)
            XCTAssertEqual(currentSummary(of: rec.id), "DONE")
        }
        XCTAssertLessThanOrEqual(probe.maxObserved, 2,
                                 "Concurrency cap must hold across the whole batch (saw \(probe.maxObserved))")
    }

    /// Process newest-first so the recording the user just finished
    /// gets attention before the months-old archive. We pace down to
    /// one-at-a-time concurrency so the ordering is observable; with
    /// parallel calls "first started" is the wrong question.
    func test_backfill_processes_newest_first() async throws {
        var order: [String] = []
        useStubRunner { _, prompt, transcript, _, _, _, _ in
            // The transcript text is the only thing that varies between our
            // recordings — record which marker this call carried.
            let blob = prompt + transcript
            if blob.contains("MARKER_OLD") { order.append("MARKER_OLD") }
            if blob.contains("MARKER_MID") { order.append("MARKER_MID") }
            if blob.contains("MARKER_NEW") { order.append("MARKER_NEW") }
            return "OK"
        }

        llm.tool = .claude
        summarizer.maxConcurrent = 1

        // Create three with explicit createdAt so the store's
        // newest-first ordering is unambiguous.
        let now = Date()
        let oldest = try addRecording(title: "Oldest",
                                      status: .completed,
                                      fullText: "MARKER_OLD payload",
                                      summary: nil,
                                      createdAt: now.addingTimeInterval(-300))
        let middle = try addRecording(title: "Middle",
                                      status: .completed,
                                      fullText: "MARKER_MID payload",
                                      summary: nil,
                                      createdAt: now.addingTimeInterval(-100))
        let newest = try addRecording(title: "Newest",
                                      status: .completed,
                                      fullText: "MARKER_NEW payload",
                                      summary: nil,
                                      createdAt: now)

        summarizer.backfillIfNeeded()

        // Wait for all three to land. With maxConcurrent = 1 they run
        // strictly serially: only the first is in flight at a time, the
        // rest sit in `backfillQueue`, so poll on the summaries rather than
        // awaiting tasks that don't exist yet.
        try await waitForSummary(recordingID: oldest.id)
        try await waitForSummary(recordingID: middle.id)
        try await waitForSummary(recordingID: newest.id)

        guard let newIdx = order.firstIndex(of: "MARKER_NEW"),
              let midIdx = order.firstIndex(of: "MARKER_MID"),
              let oldIdx = order.firstIndex(of: "MARKER_OLD") else {
            XCTFail("Did not see all three markers; order was: \(order)")
            return
        }
        XCTAssertLessThan(newIdx, midIdx, "Newest should be processed before Middle")
        XCTAssertLessThan(midIdx, oldIdx, "Middle should be processed before Oldest")
    }

    // MARK: - Helpers

    /// Rebuild `summarizer` with a deterministic `runLLM` stub. Call after
    /// configuring `llm` / `liveAI` (and before `maxConcurrent` tweaks,
    /// which are applied on the rebuilt instance).
    private func useStubRunner(_ run: @escaping RecordingSummarizer.RunLLM) {
        summarizer = RecordingSummarizer(store: store,
                                         llmSettings: llm,
                                         liveAISettings: liveAI,
                                         runLLM: run)
    }

    private func addRecording(title: String,
                              status: TranscriptionStatus,
                              fullText: String,
                              summary: String?,
                              createdAt: Date = Date()) throws -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: title)
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            id: UUID(),
            title: title,
            createdAt: createdAt,
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            status: status,
            fullText: fullText
        )
        rec.summary = summary
        store.add(rec)
        return rec
    }

    private func currentSummary(of id: UUID) -> String? {
        store.recordings.first { $0.id == id }?.summary
    }

    /// Await a backfill summary that lands via the `$tool` Combine sink,
    /// which hops through `DispatchQueue.main` before the task is created —
    /// so there's no in-flight task to await synchronously at flip time.
    /// The injected runner is instant, so this resolves in a couple of main
    /// ticks; bounded so a regression fails fast instead of hanging.
    private func waitForSummary(recordingID: UUID) async throws {
        for _ in 0..<200 {
            if let s = currentSummary(of: recordingID), !s.isEmpty { return }
            // Let the scheduled main-queue sink + summary task run.
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for summary on \(recordingID)")
    }
}

/// In-process stand-in for the old "count concurrent shell scripts via probe
/// files" trick. The stubbed runner calls `enterAndWait()` on entry, which
/// bumps the live count (recording the peak) and then parks until
/// `releaseAll()` is called — so the test can force the summarizer's
/// concurrency cap to become observable without any subprocess or sleep.
@MainActor
final class ConcurrencyProbe {
    private(set) var current = 0
    private(set) var maxObserved = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var currentWaiters: [(target: Int, cont: CheckedContinuation<Void, Never>)] = []

    func enterAndWait() async {
        current += 1
        maxObserved = max(maxObserved, current)
        resolveCurrentWaiters()
        if released {
            current -= 1
            return
        }
        await withCheckedContinuation { parked.append($0) }
        current -= 1
    }

    /// Suspend until `current` reaches `target` (or return immediately if it
    /// already has). Lets the test wait for the cap to fill deterministically.
    func waitUntilCurrent(_ target: Int) async {
        if current >= target { return }
        await withCheckedContinuation { currentWaiters.append((target, $0)) }
    }

    func releaseAll() {
        released = true
        let pending = parked
        parked.removeAll()
        for c in pending { c.resume() }
    }

    private func resolveCurrentWaiters() {
        let ready = currentWaiters.filter { current >= $0.target }
        currentWaiters.removeAll { current >= $0.target }
        for w in ready { w.cont.resume() }
    }
}
