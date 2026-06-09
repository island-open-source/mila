import SwiftUI

/// "More" detail page accessed via the sidebar. Houses the lower-priority
/// entry points that used to sit on Home as tiles — file import and
/// video → SRT subtitling. (App-audio capture is now a first-class
/// toggle on Home, not a More entry.) Stripping these off Home kept the
/// main screen focused on the Record button; users who need them reach
/// them in one extra click via the sidebar.
struct MoreView: View {
    @EnvironmentObject private var actions: QuickActionsController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("More")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                VStack(spacing: 12) {
                    MoreRow(icon: "folder.fill",
                            title: "Open Files",
                            subtitle: "Import audio or video to transcribe.") {
                        Task { await actions.openFiles() }
                    }
                    // App-audio capture moved to the Home screen as a
                    // first-class "App audio" toggle (alongside the
                    // Microphone toggle), so it's no longer a More entry.
                    MoreRow(icon: "captions.bubble.fill",
                            title: "Subtitle Video",
                            subtitle: "Pick a video, get a Mila-transcribed .srt sidecar.") {
                        Task { await actions.subtitleVideo() }
                    }
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("more.page")
    }
}

/// A single entry row on the More page. Visually closer to a Settings
/// row than a tile — heavier on text, lower on chrome, since these are
/// occasional-use actions rather than primary CTAs.
private struct MoreRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
