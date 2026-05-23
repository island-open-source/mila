import SwiftUI

/// Standardised "source" glyph for a recording row. Encapsulates the
/// special-case for Zoom recordings so every view that lists a recording
/// (history rows, queue rows, detail header, etc.) renders a consistent
/// Zoom-blue camera tile instead of the generic system-audio speaker
/// icon. Plain microphone / system-audio recordings keep their existing
/// tinted SF Symbol.
struct RecordingSourceBadge: View {
    let recording: Recording
    var size: CGFloat = 22

    /// Zoom brand blue (#2D8CFF) approximated in sRGB so the tile is
    /// instantly recognisable as a Zoom recording even at small sizes.
    private static let zoomBlue = Color(red: 0.176, green: 0.549, blue: 1.0)

    var body: some View {
        if recording.isZoomRecording {
            zoomBadge
        } else {
            sourceIcon
        }
    }

    private var zoomBadge: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Self.zoomBlue)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "video.fill")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            )
            .accessibilityLabel("Zoom recording")
            .help("Recorded from Zoom")
    }

    private var sourceIcon: some View {
        Image(systemName: recording.source.sfSymbol)
            .font(.system(size: size * 0.64, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
    }
}
