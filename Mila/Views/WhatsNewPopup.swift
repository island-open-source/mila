import SwiftUI

/// Pre-update enticement shown when Sparkle finds a newer version available.
///
/// Presented as a sheet BEFORE the user updates (we suppress Sparkle's own
/// "update available" window for scheduled checks — see `UpdaterViewModel`).
/// The goal is to make the new version feel worth grabbing: the version's
/// highlights up top, a prominent "Update Now" that hands control back to
/// Sparkle's install flow, and a low-key "Later" that dismisses gracefully.
///
/// Content comes entirely from the appcast item's release notes (the
/// installed app can't carry a not-yet-released version's notes), so what
/// shows here is whatever the developer wrote in that release's
/// `<description>`. See `WhatsNewUpdate`.
struct WhatsNewPopup: View {
    let update: WhatsNewUpdate
    let onUpdateNow: () -> Void
    let onLater: () -> Void

    /// Guard against double-firing the callbacks (e.g. Update Now + the
    /// implicit ESC-to-dismiss both landing). First action wins.
    @State private var didAct = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if update.highlights.isEmpty {
                        // No bulleted highlights parsed — show the prose
                        // notes verbatim so the popup is never empty.
                        Text(update.fullNotes.isEmpty
                             ? "A new version of Mila is ready to install."
                             : update.fullNotes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("whatsNew.notes")
                    } else {
                        ForEach(Array(update.highlights.enumerated()), id: \.offset) { index, highlight in
                            highlightRow(highlight)
                                .accessibilityIdentifier("whatsNew.highlight.\(index)")
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 460)
        .accessibilityIdentifier("whatsNew.popup")
        // ESC dismisses as "Later" — never block the user behind this sheet.
        .onExitCommand { triggerLater() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .cornerRadius(12)

            VStack(alignment: .leading, spacing: 4) {
                Text("Update available")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .textCase(.uppercase)
                Text("What's New in Mila \(update.displayVersion)")
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatsNew.title")
            }
            Spacer(minLength: 0)
        }
    }

    private func highlightRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 18)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Button("Later") { triggerLater() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("whatsNew.later")
            Spacer()
            Button {
                triggerUpdateNow()
            } label: {
                Text("Update Now")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("whatsNew.updateNow")
        }
    }

    private func triggerUpdateNow() {
        guard !didAct else { return }
        didAct = true
        onUpdateNow()
    }

    private func triggerLater() {
        guard !didAct else { return }
        didAct = true
        onLater()
    }
}
