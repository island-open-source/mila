import XCTest
import Combine
@testable import Mila

/// Unit tests for the inverse of the "meeting detected → start recording?"
/// prompt: when a meeting goes inactive while Mila is recording, offer to
/// STOP. Two layers are covered:
///
///   1. The pure decision (`MeetingPromptCoordinator.shouldShowStopPrompt`)
///      — the four gates that decide whether the stop prompt appears.
///   2. The detector's debounced active→inactive transition that emits
///      `meetingEnded` (so a momentary mic drop doesn't fire a false stop).
@MainActor
final class MeetingStopPromptTests: XCTestCase {

    // MARK: - Decision logic

    func test_recording_and_meeting_ended_triggers_stop_prompt() {
        XCTAssertTrue(
            MeetingPromptCoordinator.shouldShowStopPrompt(
                detectionEnabled: true,
                appSilenced: false,
                isRecording: true,
                promptAlreadyShowing: false
            ),
            "Recording + meeting ended + enabled should offer to stop"
        )
    }

    func test_not_recording_does_not_trigger_stop_prompt() {
        XCTAssertFalse(
            MeetingPromptCoordinator.shouldShowStopPrompt(
                detectionEnabled: true,
                appSilenced: false,
                isRecording: false,
                promptAlreadyShowing: false
            ),
            "No active recording → nothing to stop, so no prompt"
        )
    }

    func test_feature_disabled_does_not_trigger_stop_prompt() {
        XCTAssertFalse(
            MeetingPromptCoordinator.shouldShowStopPrompt(
                detectionEnabled: false,
                appSilenced: false,
                isRecording: true,
                promptAlreadyShowing: false
            ),
            "Meeting detection disabled in Settings gates the whole feature"
        )
    }

    func test_app_silenced_does_not_trigger_stop_prompt() {
        XCTAssertFalse(
            MeetingPromptCoordinator.shouldShowStopPrompt(
                detectionEnabled: true,
                appSilenced: true,
                isRecording: true,
                promptAlreadyShowing: false
            ),
            "A \"don't show for X\"-silenced app should not stop-prompt either"
        )
    }

    func test_existing_prompt_blocks_a_second_stop_prompt() {
        XCTAssertFalse(
            MeetingPromptCoordinator.shouldShowStopPrompt(
                detectionEnabled: true,
                appSilenced: false,
                isRecording: true,
                promptAlreadyShowing: true
            ),
            "Never stack a second floating panel on top of an existing one"
        )
    }

    // MARK: - Auto-dismiss when recording ends elsewhere

    /// The bug this fixes: the stop prompt is up (≤10s countdown) and the
    /// user stops recording through ANOTHER path (Record button, hotkey,
    /// system sleep). The prompt must tear down rather than leave a dead
    /// "Stop recording" button.
    func test_stop_prompt_dismisses_when_recording_ends() {
        XCTAssertTrue(
            MeetingPromptCoordinator.shouldDismissStopPrompt(
                stopPromptShowing: true,
                isRecording: false
            ),
            "A showing stop prompt must auto-dismiss once recording is no longer active"
        )
    }

    func test_stop_prompt_stays_while_recording_continues() {
        XCTAssertFalse(
            MeetingPromptCoordinator.shouldDismissStopPrompt(
                stopPromptShowing: true,
                isRecording: true
            ),
            "While recording is still active the stop prompt's button is live — keep it up"
        )
    }

    /// The start prompt (and the no-prompt case) never set `stopPromptShowing`,
    /// so recording-state changes must not dismiss anything through this path.
    func test_no_dismiss_when_stop_prompt_not_showing() {
        XCTAssertFalse(
            MeetingPromptCoordinator.shouldDismissStopPrompt(
                stopPromptShowing: false,
                isRecording: false
            ),
            "With no stop prompt up (start prompt or nothing), recording-end must not dismiss"
        )
    }

    // MARK: - Detector transition (debounce)

    /// A single inactive poll must NOT fire `meetingEnded` — that's the
    /// brief mic-drop case (mute/unmute, device switch) we deliberately
    /// ride out. `endConfirmationPolls: 2` means two consecutive inactive
    /// polls are required.
    func test_brief_drop_does_not_fire_meeting_ended() {
        let detector = MeetingDetector(endConfirmationPolls: 2)
        var ended: [MeetingDetector.App] = []
        let cancellable = detector.meetingEnded.sink { ended.append($0) }
        defer { cancellable.cancel() }

        let zoom = MeetingDetector.supportedApps[0]
        detector.simulatePollForTesting(activeBundleIDs: [zoom.bundleID])  // active
        detector.simulatePollForTesting(activeBundleIDs: [])               // 1 inactive
        detector.simulatePollForTesting(activeBundleIDs: [zoom.bundleID])  // recovered

        XCTAssertTrue(ended.isEmpty,
                      "A single inactive poll before recovery must not fire meetingEnded")
    }

    /// Sustained inactivity (>= `endConfirmationPolls`) fires exactly once.
    func test_sustained_inactivity_fires_meeting_ended_once() {
        let detector = MeetingDetector(endConfirmationPolls: 2)
        var ended: [MeetingDetector.App] = []
        let cancellable = detector.meetingEnded.sink { ended.append($0) }
        defer { cancellable.cancel() }

        let zoom = MeetingDetector.supportedApps[0]
        detector.simulatePollForTesting(activeBundleIDs: [zoom.bundleID])  // active
        detector.simulatePollForTesting(activeBundleIDs: [])               // 1 inactive
        detector.simulatePollForTesting(activeBundleIDs: [])               // 2 inactive → fire
        detector.simulatePollForTesting(activeBundleIDs: [])               // still inactive, no re-fire

        XCTAssertEqual(ended.map(\.bundleID), [zoom.bundleID],
                       "Sustained inactivity should fire meetingEnded exactly once")
    }

    /// A meeting that never went active can't "end".
    func test_never_active_never_fires_meeting_ended() {
        let detector = MeetingDetector(endConfirmationPolls: 2)
        var ended: [MeetingDetector.App] = []
        let cancellable = detector.meetingEnded.sink { ended.append($0) }
        defer { cancellable.cancel() }

        detector.simulatePollForTesting(activeBundleIDs: [])
        detector.simulatePollForTesting(activeBundleIDs: [])
        detector.simulatePollForTesting(activeBundleIDs: [])

        XCTAssertTrue(ended.isEmpty,
                      "An app that was never in a meeting should never fire meetingEnded")
    }

    /// Leaving and rejoining produces a fresh `meetingEnded` the second
    /// time too (the end-detector re-arms on each fresh active run).
    func test_rejoin_then_end_fires_meeting_ended_again() {
        let detector = MeetingDetector(endConfirmationPolls: 2)
        var ended: [MeetingDetector.App] = []
        let cancellable = detector.meetingEnded.sink { ended.append($0) }
        defer { cancellable.cancel() }

        let zoom = MeetingDetector.supportedApps[0]
        // First meeting + end.
        detector.simulatePollForTesting(activeBundleIDs: [zoom.bundleID])
        detector.simulatePollForTesting(activeBundleIDs: [])
        detector.simulatePollForTesting(activeBundleIDs: [])  // fire #1
        // Second meeting + end.
        detector.simulatePollForTesting(activeBundleIDs: [zoom.bundleID])
        detector.simulatePollForTesting(activeBundleIDs: [])
        detector.simulatePollForTesting(activeBundleIDs: [])  // fire #2

        XCTAssertEqual(ended.count, 2,
                       "Re-joining and ending a second meeting should fire meetingEnded again")
    }
}
