import AppKit
import SwiftUI
import Combine

/// Floating panel that asks "Want me to transcribe this meeting?" when a
/// supported app (Zoom, …) appears to be in a call.
///
/// Lifecycle:
///   * `MilaApp` constructs a single `MeetingPromptCoordinator`, hands
///     it the detector and the action controller, and calls `start()`.
///   * The coordinator subscribes to `MeetingDetector.meetingStarted`
///     and renders the panel when an event fires (subject to the
///     user's enabled / silenced settings).
///   * The panel auto-dismisses after `autoDismissSeconds` unless the
///     user is hovering it (a sleek progress bar at the bottom shows
///     the countdown; hovering freezes the bar).
///
/// The panel is a borderless `NSPanel` floating at status-bar level,
/// positioned top-right of the active screen.
@MainActor
final class MeetingPromptCoordinator: ObservableObject {
    private let detector: MeetingDetector
    private let settings: MeetingDetectionSettings
    private let actions: QuickActionsController
    private var startCancellable: AnyCancellable?
    private var endCancellable: AnyCancellable?
    private var recordingStateCancellable: AnyCancellable?
    private var window: NSPanel?
    /// True only while the currently-presented panel is the *stop* prompt.
    /// Used to auto-dismiss that prompt if recording ends through any other
    /// path (Record button, hotkey, sleep) during its countdown — a dead
    /// "Stop recording" button is worse than no prompt. The start prompt is
    /// untouched by this.
    private var stopPromptShowing = false

    init(detector: MeetingDetector,
         settings: MeetingDetectionSettings,
         actions: QuickActionsController) {
        self.detector = detector
        self.settings = settings
        self.actions = actions
    }

    /// Pure decision for whether the *stop* prompt should appear when a
    /// meeting goes inactive. Extracted so it's unit-testable without a
    /// real Zoom: the inputs are exactly the three things that gate the
    /// prompt. NOT gated on how the recording started — a manual record and
    /// an auto-prompt record are treated identically.
    ///
    /// - Parameters:
    ///   - detectionEnabled: the user's `MeetingDetectionSettings.enabled`
    ///     toggle — the whole feature is off when this is false.
    ///   - appSilenced: whether the user chose "don't show this for X" for
    ///     the app whose meeting just ended.
    ///   - isRecording: whether Mila is actively recording right now.
    ///   - promptAlreadyShowing: whether a prompt panel is already up (we
    ///     never stack a second one).
    static func shouldShowStopPrompt(detectionEnabled: Bool,
                                     appSilenced: Bool,
                                     isRecording: Bool,
                                     promptAlreadyShowing: Bool) -> Bool {
        guard detectionEnabled else { return false }
        guard !appSilenced else { return false }
        guard isRecording else { return false }
        guard !promptAlreadyShowing else { return false }
        return true
    }

    /// Pure decision for whether a *showing* stop prompt should now
    /// auto-dismiss. The stop prompt only makes sense while a recording is
    /// live — its sole action is "stop recording." If recording ends through
    /// any other path during the prompt's countdown (Record button, hotkey,
    /// system sleep, etc.), the button becomes a dead no-op, so we tear the
    /// prompt down. Only applies to the stop prompt; the start prompt is left
    /// alone. Extracted so it's unit-testable without a real Zoom / panel.
    static func shouldDismissStopPrompt(stopPromptShowing: Bool,
                                        isRecording: Bool) -> Bool {
        stopPromptShowing && !isRecording
    }

    func start() {
        startCancellable = detector.meetingStarted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in
                self?.handleMeetingStart(app: app)
            }
        endCancellable = detector.meetingEnded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in
                self?.handleMeetingEnd(app: app)
            }
        // Auto-dismiss a showing stop prompt the moment recording leaves the
        // active state through any path — `activeJob` is what backs
        // `isRecording`, so observing it covers the Record button, hotkeys,
        // and system-sleep stops alike.
        recordingStateCancellable = actions.$activeJob
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.dismissStopPromptIfRecordingEnded()
            }
        if settings.enabled {
            detector.start()
        }
    }

    func stop() {
        startCancellable?.cancel()
        startCancellable = nil
        endCancellable?.cancel()
        endCancellable = nil
        recordingStateCancellable?.cancel()
        recordingStateCancellable = nil
        detector.stop()
        hidePanel()
    }

    /// Bind the detector's start/stop to the user's enabled toggle.
    func bindEnabledChanges() {
        // Re-observe whenever `enabled` flips: if the user disables
        // detection, stop polling and dismiss any visible prompt;
        // if they re-enable, restart polling.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.settings.enabled {
                    self.detector.start()
                } else {
                    self.detector.stop()
                    self.hidePanel()
                }
            }
        }
    }

    private func handleMeetingStart(app: MeetingDetector.App) {
        // Already prompting (or recording, or a sheet is up) — don't
        // pile a second floating panel on top.
        guard window == nil else { return }
        guard !actions.isRecording else { return }
        guard settings.enabled else { return }
        guard !settings.isDisabled(forBundleID: app.bundleID) else { return }

        showStartPanel(for: app)
    }

    /// The inverse of `handleMeetingStart`: a meeting we were tracking went
    /// inactive. If Mila is recording (regardless of how that recording was
    /// started) and the feature is enabled, offer to stop.
    private func handleMeetingEnd(app: MeetingDetector.App) {
        guard Self.shouldShowStopPrompt(
            detectionEnabled: settings.enabled,
            appSilenced: settings.isDisabled(forBundleID: app.bundleID),
            isRecording: actions.isRecording,
            promptAlreadyShowing: window != nil
        ) else { return }

        showStopPanel(for: app)
    }

    /// Fires on every `actions.activeJob` change. If the stop prompt is up
    /// and recording is no longer active, dismiss it — the "Stop recording"
    /// button would otherwise be a dead no-op (recording already ended).
    private func dismissStopPromptIfRecordingEnded() {
        guard Self.shouldDismissStopPrompt(
            stopPromptShowing: stopPromptShowing,
            isRecording: actions.isRecording
        ) else { return }
        hidePanel()
    }

    private func showStartPanel(for app: MeetingDetector.App) {
        let view = MeetingPromptView(
            app: app,
            kind: .start,
            onPrimary: { [weak self] in
                self?.hidePanel()
                Task { @MainActor [weak self] in
                    // Auto-prompt always captures system audio — the
                    // whole point of detecting a meeting is to grab the
                    // other participants' audio alongside the user's
                    // mic. If the user only wanted mic, they can switch
                    // sources from the recording chip after the fact.
                    await self?.actions.toggleRecord(withSystemAudio: true)
                }
            },
            onDismiss: { [weak self] in
                // "Not now" or the auto-dismiss timeout — just hide. We no
                // longer snooze: the detector re-arms when the meeting ends
                // (mic capture stops), so the *next* meeting prompts again,
                // while its `firedFor` prevents re-prompting within the
                // current meeting. "Don't show for X" stops prompts entirely.
                self?.hidePanel()
            },
            onSilenceApp: { [weak self] in
                self?.settings.disable(bundleID: app.bundleID)
                self?.hidePanel()
            }
        )
        presentPanel(hosting: view)
    }

    /// Mirror of `showStartPanel` for the end-of-meeting case. The primary
    /// action stops the active recording; "Keep recording" just dismisses.
    private func showStopPanel(for app: MeetingDetector.App) {
        let view = MeetingPromptView(
            app: app,
            kind: .stop,
            onPrimary: { [weak self] in
                self?.hidePanel()
                Task { @MainActor [weak self] in
                    await self?.actions.stopRecording()
                }
            },
            onDismiss: { [weak self] in
                // "Keep recording" or the auto-dismiss timeout — leave the
                // recording running and just hide the panel.
                self?.hidePanel()
            },
            onSilenceApp: { [weak self] in
                self?.settings.disable(bundleID: app.bundleID)
                self?.hidePanel()
            }
        )
        stopPromptShowing = true
        presentPanel(hosting: view)
    }

    private func presentPanel(hosting view: MeetingPromptView) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 168)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: view)
        positionTopTrailing(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.window = panel
    }

    private func hidePanel() {
        stopPromptShowing = false
        guard let panel = window else { return }
        self.window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func positionTopTrailing(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.maxX - size.width - 16
        let y = visible.maxY - size.height - 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The sleek body of the prompt. Auto-dismisses after a short window,
/// with the progress bar across the bottom acting as the countdown.
/// Hovering pauses the bar (and freezes the auto-dismiss timer).
private struct MeetingPromptView: View {
    /// Which prompt this is — start a recording (meeting detected) or stop
    /// one (meeting ended). Drives all the copy, the primary button style,
    /// and the accessibility identifiers so a single view body serves both.
    enum Kind {
        case start
        case stop
    }

    let app: MeetingDetector.App
    let kind: Kind
    let onPrimary: () -> Void
    let onDismiss: () -> Void
    let onSilenceApp: () -> Void

    /// How long the prompt stays up if the user doesn't interact.
    private let autoDismissSeconds: Double = 10
    /// Granularity of the progress bar tick. 30 fps is smooth without
    /// being wasteful.
    private let tickInterval: Double = 1.0 / 30.0

    @State private var elapsed: Double = 0
    @State private var hovering = false
    @State private var expanded = false
    @State private var dismissed = false
    /// Wall-clock anchor used to track elapsed time accurately even when
    /// the system briefly throttles SwiftUI's timer callbacks.
    @State private var lastTick: Date = Date()

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Progress bar lives at the TOP of the card now: it reads
            // as "time is running out from here downward" — and crucially
            // it sits INSIDE the rounded corners (the whole VStack gets
            // clipped to the card shape below) so the bar never extends
            // past the card edge.
            progressBar
            content
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if expanded {
                Divider().opacity(0.4)
                expandedActions
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .background(cardBackground)
        // Clip everything (including the progress bar) to the card's
        // shape so the bar doesn't bleed past the corners.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .frame(width: 360)
        .onHover { hovering = $0 }
        .onReceive(timer) { _ in tick() }
        .onAppear { lastTick = Date() }
        .accessibilityIdentifier("\(identifierPrefix).\(app.bundleID)")
    }

    /// Accessibility-identifier prefix, distinct per kind so UI tests can
    /// target the start prompt and the stop prompt independently.
    private var identifierPrefix: String {
        switch kind {
        case .start: return "meetingPrompt"
        case .stop:  return "meetingStopPrompt"
        }
    }

    private var titleText: String {
        switch kind {
        case .start: return "\(app.displayName) meeting detected"
        case .stop:  return "\(app.displayName) meeting ended"
        }
    }

    private var subtitleText: String {
        switch kind {
        case .start: return "Want Mila to transcribe this call?"
        case .stop:  return "Stop recording now?"
        }
    }

    private var primaryButtonText: String {
        switch kind {
        case .start: return "Start transcribing"
        case .stop:  return "Stop recording"
        }
    }

    private var dismissButtonText: String {
        switch kind {
        case .start: return "Not now"
        case .stop:  return "Keep recording"
        }
    }

    /// Brighter card fill — `regularMaterial` skews dark on macOS in
    /// dark mode and against bright backgrounds reads as "faded notice
    /// you can ignore." Layering a near-opaque window background tint
    /// on top of `thickMaterial` keeps the vibrant feel while making
    /// the card itself clearly foreground.
    private var cardBackground: some View {
        ZStack {
            Rectangle().fill(.thickMaterial)
            Rectangle().fill(Color(NSColor.windowBackgroundColor).opacity(0.55))
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            // App icon — uses Mila's app icon to anchor brand identity.
            // The Mila wordmark + meeting-detection feature is what this
            // prompt represents; showing Zoom's icon could be mistaken
            // for a Zoom notification.
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(titleText)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("More options")
                    .accessibilityIdentifier("\(identifierPrefix).chevron")
                }

                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: triggerPrimary) {
                        Text(primaryButtonText)
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("\(identifierPrefix).primary")

                    Button(action: triggerDismiss) {
                        Text(dismissButtonText)
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("\(identifierPrefix).dismiss")
                }
                .padding(.top, 4)
            }
        }
    }

    private var expandedActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: triggerSilence) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .font(.caption)
                    Text("Don't show this for \(app.displayName)")
                        .font(.callout)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(identifierPrefix).silence")

            Text("You can re-enable this in Settings → Meetings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(hovering ? Color.secondary : Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(progressFraction))
                    .animation(.linear(duration: tickInterval), value: progressFraction)
            }
        }
        .frame(height: 3)
        // Don't clip the bar to a separate rounded rect — the parent
        // already clips the whole card to its corner radius, which is
        // what keeps the bar from bleeding past the edges.
    }

    private var progressFraction: Double {
        let remaining = max(0, autoDismissSeconds - elapsed)
        return max(0, min(1, remaining / autoDismissSeconds))
    }

    private func tick() {
        guard !dismissed else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if hovering { return }   // freeze the countdown while the cursor is over the card
        elapsed += dt
        if elapsed >= autoDismissSeconds {
            triggerDismiss()
        }
    }

    private func triggerPrimary() {
        guard !dismissed else { return }
        dismissed = true
        onPrimary()
    }

    private func triggerDismiss() {
        guard !dismissed else { return }
        dismissed = true
        onDismiss()
    }

    private func triggerSilence() {
        guard !dismissed else { return }
        dismissed = true
        onSilenceApp()
    }
}
