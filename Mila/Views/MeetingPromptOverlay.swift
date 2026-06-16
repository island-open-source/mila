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
    private var cancellable: AnyCancellable?
    private var window: NSPanel?

    init(detector: MeetingDetector,
         settings: MeetingDetectionSettings,
         actions: QuickActionsController) {
        self.detector = detector
        self.settings = settings
        self.actions = actions
    }

    func start() {
        cancellable = detector.meetingStarted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in
                self?.handleMeetingStart(app: app)
            }
        if settings.enabled {
            detector.start()
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
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

        showPanel(for: app)
    }

    private func showPanel(for app: MeetingDetector.App) {
        let view = MeetingPromptView(
            app: app,
            onStart: { [weak self] in
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
    let app: MeetingDetector.App
    let onStart: () -> Void
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
        .accessibilityIdentifier("meetingPrompt.\(app.bundleID)")
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
                    Text("\(app.displayName) meeting detected")
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
                    .accessibilityIdentifier("meetingPrompt.chevron")
                }

                Text("Want Mila to transcribe this call?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: triggerStart) {
                        Text("Start transcribing")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("meetingPrompt.start")

                    Button(action: triggerDismiss) {
                        Text("Not now")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("meetingPrompt.dismiss")
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
            .accessibilityIdentifier("meetingPrompt.silence")

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

    private func triggerStart() {
        guard !dismissed else { return }
        dismissed = true
        onStart()
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
