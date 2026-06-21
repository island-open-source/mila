import XCTest
@testable import Mila

/// Validates the Live AI LLM-feed min-interval throttle (the
/// `llmMinIntervalSeconds` floor added to cut the per-recording CPU cost
/// of spawning a `claude` / `cursor-agent` subprocess on every transcript
/// segment).
///
/// Everything here is deterministic and timing-free where it matters:
///   * `kickDelay` is a pure function — exercised directly.
///   * The behavioural tests drive the REAL `feed → scheduleKick → kick`
///     path with a stubbed `performCall` (no subprocess) and an injected
///     `nowProvider` (no wall-clock dependence), so they run in
///     milliseconds and don't flake on hosted CI runners.
///
/// What this does NOT cover: the SwiftUI re-render hypothesis. That can't
/// be measured reliably on a headless hosted runner and needs local
/// Instruments — see the investigation notes, not a CI test.
@MainActor
final class LiveAIThrottleTests: XCTestCase {

    // MARK: - Helpers

    /// Mutable, controllable clock for `nowProvider`.
    private final class TestClock {
        var now: Date
        init(_ start: Date) { now = start }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// Records each stubbed LLM call so tests can count invocations.
    private final class CallLog {
        var startedAt: [Date] = []
        var transcripts: [String] = []
    }

    private func makeSession(minInterval: Double,
                             clock: TestClock,
                             log: CallLog,
                             suite: String) -> LiveAISession {
        UserDefaults().removePersistentDomain(forName: "\(suite).llm")
        UserDefaults().removePersistentDomain(forName: "\(suite).live")
        let llm = LLMSettings(defaults: UserDefaults(suiteName: "\(suite).llm")!)
        llm.tool = .claude   // isConfigured == (tool != .none); also enables session/delta mode
        let live = LiveAISettings(defaults: UserDefaults(suiteName: "\(suite).live")!)
        live.llmMinIntervalSeconds = minInterval

        let session = LiveAISession(llmSettings: llm, liveAISettings: live)
        session.nowProvider = { clock.now }
        session.performCall = { call in
            log.startedAt.append(clock.now)
            log.transcripts.append(call.transcript)
            // Minimal valid envelope so parseEnvelope succeeds and the
            // success path runs (sets lastTranscriptSent for delta mode).
            return #"{"summary":"ok","items":[]}"#
        }
        session.start()   // allocates the Claude session id → delta mode
        return session
    }

    /// Spin until the in-flight tick clears. The stub returns instantly,
    /// so this resolves in a few hops; the timeout only guards a hang.
    private func waitUntilIdle(_ session: LiveAISession,
                               timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while session.isThinking && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }
    }

    // MARK: - Pure throttle core

    func test_kickDelay_firstCall_isImmediate() {
        XCTAssertEqual(
            LiveAISession.kickDelay(now: Date(), lastKickStartedAt: nil, minInterval: 20),
            0, accuracy: 1e-9)
    }

    func test_kickDelay_withinInterval_returnsRemaining() {
        let now = Date()
        XCTAssertEqual(
            LiveAISession.kickDelay(now: now,
                                    lastKickStartedAt: now.addingTimeInterval(-5),
                                    minInterval: 20),
            15, accuracy: 1e-6)
    }

    func test_kickDelay_afterInterval_isImmediate() {
        let now = Date()
        XCTAssertEqual(
            LiveAISession.kickDelay(now: now,
                                    lastKickStartedAt: now.addingTimeInterval(-25),
                                    minInterval: 20),
            0, accuracy: 1e-9)
    }

    func test_kickDelay_measuredFromStart_notEnd() {
        // A call that already ran longer than the interval adds no extra
        // delay — the floor is measured from the previous START.
        let now = Date()
        XCTAssertEqual(
            LiveAISession.kickDelay(now: now,
                                    lastKickStartedAt: now.addingTimeInterval(-100),
                                    minInterval: 20),
            0, accuracy: 1e-9)
    }

    func test_kickDelay_zeroInterval_disablesThrottle() {
        let now = Date()
        XCTAssertEqual(
            LiveAISession.kickDelay(now: now,
                                    lastKickStartedAt: now.addingTimeInterval(-1),
                                    minInterval: 0),
            0, accuracy: 1e-9)
    }

    // MARK: - Behaviour: the throttle suppresses rapid feeds

    func test_rapidFeeds_withinInterval_fireOnlyOneCall() async {
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 0))
        let log = CallLog()
        let session = makeSession(minInterval: 1000, clock: clock, log: log,
                                  suite: "ThrottleSuppress")
        defer { session.cancel() } // cancels any deferred pending task

        // First feed → fires immediately (no prior call).
        session.feed(transcript: "one")
        await waitUntilIdle(session)
        XCTAssertEqual(log.startedAt.count, 1, "first feed should fire")

        // Several more feeds, all well within the 1000 s floor and all
        // after the first call completed → each is deferred, none fires.
        for (i, t) in ["one two", "one two three", "one two three four"].enumerated() {
            clock.advance(Double(i + 1) * 3) // +3s, +6s, +9s — all << floor
            session.feed(transcript: t)
            await Task.yield()
        }
        XCTAssertEqual(log.startedAt.count, 1,
                       "within-interval feeds must not spawn additional calls")
    }

    func test_immediateFeed_bypassesThrottle() async {
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 0))
        let log = CallLog()
        let session = makeSession(minInterval: 1000, clock: clock, log: log,
                                  suite: "ThrottleImmediate")
        defer { session.cancel() }

        session.feed(transcript: "alpha")
        await waitUntilIdle(session)
        XCTAssertEqual(log.startedAt.count, 1)

        // Still inside the huge floor, but immediate must fire anyway.
        clock.advance(2)
        session.feed(transcript: "alpha beta", immediate: true)
        await waitUntilIdle(session)
        XCTAssertEqual(log.startedAt.count, 2,
                       "immediate feed must bypass the min-interval floor")
    }

    func test_feed_afterIntervalElapses_firesAgain() async {
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 0))
        let log = CallLog()
        let session = makeSession(minInterval: 20, clock: clock, log: log,
                                  suite: "ThrottleElapsed")
        defer { session.cancel() }

        session.feed(transcript: "a")
        await waitUntilIdle(session)
        XCTAssertEqual(log.startedAt.count, 1)

        // Advance past the floor — the next feed is immediately eligible
        // (delay computes to 0) and fires on the spot.
        clock.advance(25)
        session.feed(transcript: "a b")
        await waitUntilIdle(session)
        XCTAssertEqual(log.startedAt.count, 2,
                       "a feed after the interval elapses should fire")
    }

    // MARK: - Regression: stop-time flush bypasses the floor

    func test_awaitFinalTick_flushesFinalTranscript_despiteFloor() async {
        // Mirrors QuickActionsController's stop sequence: feed(immediate:)
        // then awaitFinalTick(). Even with a large floor, the final
        // transcript must reach the LLM so the saved summary is complete.
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 0))
        let log = CallLog()
        let session = makeSession(minInterval: 1000, clock: clock, log: log,
                                  suite: "ThrottleFinal")
        defer { session.cancel() }

        session.feed(transcript: "intro")
        await waitUntilIdle(session)
        XCTAssertEqual(log.startedAt.count, 1)

        clock.advance(3) // still inside the floor
        session.feed(transcript: "intro plus the closing remarks", immediate: true)
        await session.awaitFinalTick()

        XCTAssertEqual(log.startedAt.count, 2,
                       "stop-time flush must run despite the floor")
        XCTAssertTrue(log.transcripts.last?.contains("closing remarks") == true,
                      "final call should carry the closing transcript delta")
    }

    // (Removed `test_callFrequency_reduction_over_15min_meeting`: it asserted
    // on a local arithmetic closure, never touching LiveAISession/kickDelay,
    // so it would have passed even with the throttle removed. The pure
    // `kickDelay` cases above + the behavioural feed()/clock tests cover the
    // real throttle.)
}
