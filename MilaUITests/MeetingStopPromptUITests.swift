import XCTest

/// GUI automation for the end-of-meeting STOP prompt. Launches the app with
/// `--ui-test-simulate-meeting-ended`, which starts a fake recording (no
/// AVAudioEngine / no real Zoom) and then fires the detector's
/// `meetingEnded` event for Zoom. We assert the floating stop prompt
/// (`meetingStopPrompt.*`) appears with its primary "Stop recording" button.
///
/// This exercises the production presentation path
/// (`MeetingPromptCoordinator.handleMeetingEnd` → `showStopPanel`); the only
/// thing faked is the trigger, since a real Zoom call can't run on CI.
final class MeetingStopPromptUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_stop_prompt_appears_when_meeting_ends_while_recording() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-simulate-meeting-ended"]
        app.launch()

        // The stop prompt is a borderless NSPanel hosting the SwiftUI card.
        // Match the kind-specific accessibility identifier prefix.
        let stopPrompt = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'meetingStopPrompt'"))
            .firstMatch
        XCTAssertTrue(stopPrompt.waitForExistence(timeout: 15),
                      "Stop-recording prompt did not appear after the meeting ended while recording")

        // The primary action button should read / identify as "Stop recording".
        let stopButton = app.descendants(matching: .any)
            .matching(identifier: "meetingStopPrompt.primary")
            .firstMatch
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5),
                      "Stop-recording prompt is missing its primary 'Stop recording' button")
    }
}
