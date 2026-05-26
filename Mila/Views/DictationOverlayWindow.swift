import AppKit
import SwiftUI

/// A small floating panel shown while dictation is active.
/// Renders a blue pill with an animated white equalizer (or a spinner while busy).
@MainActor
final class DictationOverlayWindow {
    static let shared = DictationOverlayWindow()

    private var window: NSPanel?
    private let viewModel = DictationOverlayModel()

    /// Slim pill while idle / no live text yet. Expands when the live
    /// transcriber starts producing words so the user sees what's being
    /// captured before they release the hotkey.
    private static let panelSize = NSSize(width: 320, height: 64)

    func show() {
        if window == nil { createWindow() }
        viewModel.busy = false
        viewModel.level = 0
        guard let window else { return }
        positionAtBottomCenter(window)
        window.orderFrontRegardless()
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }

    func updateLevel(_ value: Float) {
        withAnimation(.easeInOut(duration: 0.08)) {
            viewModel.level = max(0, min(1, value))
        }
    }

    /// Show the latest live-transcript text from `LiveTranscriber`. Empty
    /// string collapses the text area so the overlay stays small until
    /// there's something to display.
    func updateLiveText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.liveText = trimmed
        }
    }

    /// Tell the overlay which language the user is dictating in so the
    /// live text strip can flip to RTL alignment for Hebrew (truncation
    /// dots land on the right edge, matching reading direction).
    func setLanguage(_ code: String) {
        viewModel.language = code
    }

    func setBusy(_ busy: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.busy = busy
        }
    }

    private func createWindow() {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(
            rootView: DictationOverlayContent(viewModel: viewModel)
        )
        self.window = panel
    }

    private func positionAtBottomCenter(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 80
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class DictationOverlayModel: ObservableObject {
    @Published var level: Float = 0
    @Published var busy: Bool = false
    /// Latest live-transcript text. Empty means "show nothing" — the
    /// overlay's text area collapses to zero height when this is empty
    /// so the pill stays compact at the start of a dictation.
    @Published var liveText: String = ""
    /// Language of the current dictation. Drives RTL handling for the
    /// live-text strip (Hebrew dictation places truncation dots on the
    /// right, matching reading direction).
    @Published var language: String = "en"
}

private struct DictationOverlayContent: View {
    @ObservedObject var viewModel: DictationOverlayModel

    private let pillColor = Color(red: 0.20, green: 0.55, blue: 0.95)
    private var isRTL: Bool { viewModel.language == "he" }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Capsule(style: .continuous)
                    .fill(pillColor)
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )

                if viewModel.busy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                        .transition(.opacity)
                } else {
                    EqualizerBars(level: viewModel.level)
                        .transition(.opacity)
                }
            }
            .frame(width: 150, height: 36)

            if !viewModel.liveText.isEmpty {
                Text(viewModel.liveText)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(isRTL ? .trailing : .leading)
                    .frame(maxWidth: 300, alignment: isRTL ? .trailing : .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 8))
                    .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 6)
        .frame(width: 320, alignment: .center)
    }
}

/// White equalizer bars driven by a TimelineView so they keep a subtle
/// idle wobble even when the audio level is zero.
private struct EqualizerBars: View {
    var level: Float

    private let barCount = 12
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3
    private let minHeight: CGFloat = 6
    private let maxExtra: CGFloat = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(Color.white)
                        .frame(width: barWidth, height: barHeight(index: i, time: time))
                }
            }
            .animation(.easeInOut(duration: 0.08), value: level)
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let phase = Double(index) * 0.45
        let wobble = (sin(time * 7.0 + phase) + 1) / 2 // 0...1
        let amp = max(Double(level), 0.05)
        return minHeight + CGFloat(amp * Double(maxExtra) * wobble)
    }
}
