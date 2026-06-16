import SwiftUI
import AppKit

/// Live-AI overview block — summary + action items — rendered the same
/// way in two places: the recording detail screen
/// (`RecordingDetailView`) and the post-record rename sheet
/// (`RenameRecordingSheet`). Kept in a single internal type so a layout
/// tweak in one place can't silently desync from the other (Bugbot
/// finding on PR #25).
///
/// The two call sites differ only in the *outer* chrome — the detail
/// view caps the section at 240 pt inside a `ScrollView` and adds a
/// trailing `Divider`; the rename sheet wraps it in a
/// `.regularMaterial` card. Both use `AIOverviewSection` below for the
/// inner content (Summary header + body, Action items header + list).
///
/// RTL: section-level decision matches the live view — prefer the
/// actual text content (`isPredominantlyHebrew` over the summary +
/// items blob) over `recordingLanguage`, so a conversation that
/// happened in Hebrew with the dropdown stuck on English still aligns
/// to the right edge.
struct AIOverviewSection: View {
    let summary: String?
    let items: [ActionItem]
    let recordingLanguage: String
    /// When set, the summary block exposes a "Regenerate summary"
    /// context-menu action that calls this closure. Hidden in the
    /// rename sheet (which doesn't have a summarizer to call) and
    /// in views that don't pass it through.
    var onRegenerateSummary: (() -> Void)? = nil
    /// Forces the "Summarizing…" spinner UI without requiring an
    /// existing summary string — used while a regenerate / backfill
    /// is in flight on a recording that has nothing yet (so
    /// `summary` is nil but we still want feedback that work is
    /// happening).
    var isSummarizing: Bool = false

    /// True iff there's at least one non-empty piece to show. Callers
    /// can use this to collapse their wrapper (avoiding an empty card
    /// in the rename sheet or an empty header strip in the detail
    /// view).
    var hasContent: Bool {
        (summary?.isEmpty == false) || !items.isEmpty || isSummarizing
    }

    private var sectionIsRTL: Bool {
        let blob = (summary ?? "") + " " + items.map(\.text).joined(separator: " ")
        return blob.isPredominantlyHebrew || recordingLanguage == "he"
    }

    var body: some View {
        if hasContent {
            let alignmentValue: Alignment = sectionIsRTL ? .trailing : .leading
            let multilineAlignment: TextAlignment = sectionIsRTL ? .trailing : .leading
            VStack(alignment: .leading, spacing: 12) {
                let summaryText = summary ?? ""
                if !summaryText.isEmpty || isSummarizing {
                    summaryView(summaryText,
                                alignment: alignmentValue,
                                multiline: multilineAlignment)
                }
                if !items.isEmpty {
                    actionItemsView(alignment: alignmentValue,
                                    multiline: multilineAlignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignmentValue)
        }
    }

    private func summaryView(_ text: String,
                             alignment: Alignment,
                             multiline: TextAlignment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Summary", systemImage: "sparkles")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                if isSummarizing {
                    // Spinner sits next to the section title so a
                    // regenerate / backfill is visible without
                    // obscuring the (still-valid) previous summary
                    // text below.
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("detail.summary.spinner")
                    Text("Summarizing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !text.isEmpty {
                    // One-click copy of the whole summary. The selectable
                    // text + context menu stay; a visible button just makes
                    // "grab the summary" obvious (matches the transcript's
                    // Copy button).
                    Button {
                        AIOverviewSection.copyToPasteboard(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy summary")
                    .accessibilityIdentifier("detail.summary.copy")
                }
            }
            // Selectable + right-clickable so users can grab the summary
            // into another doc / chat. `textSelection(.enabled)` gives
            // drag-select; the context menu mirrors the macOS-native
            // "Copy" affordance plus a labelled "Copy summary" option,
            // and — when the caller wired it — a "Regenerate summary"
            // entry that re-runs the LLM against the current transcript.
            if !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .multilineTextAlignment(multiline)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy summary") {
                            AIOverviewSection.copyToPasteboard(text)
                        }
                        if let onRegenerateSummary {
                            Divider()
                            Button("Regenerate summary") {
                                onRegenerateSummary()
                            }
                            .disabled(isSummarizing)
                            .accessibilityIdentifier("detail.summary.regenerate")
                        }
                    }
            } else if isSummarizing {
                // Backfill case: no summary text yet, but a CLI call
                // is in flight. A placeholder line gives the user
                // something to point at while waiting.
                Text("Generating summary…")
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .multilineTextAlignment(multiline)
            }
        }
    }

    private func actionItemsView(alignment: Alignment,
                                 multiline: TextAlignment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Action items", systemImage: "checklist")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer(minLength: 8)
                // Each row is individually selectable + copyable, but they're
                // separate Text views so you can't drag-select them all at
                // once. This copies every item as a bulleted block in one
                // click — the affordance users were missing for action items.
                Button {
                    AIOverviewSection.copyToPasteboard(Self.actionItemsText(items))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy action items")
                .accessibilityIdentifier("detail.actionItems.copy")
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    ActionItemRow(text: item.text,
                                  alignment: alignment,
                                  multiline: multiline)
                }
            }
        }
    }

    /// All action items as a bulleted plain-text block, for one-click copy.
    fileprivate static func actionItemsText(_ items: [ActionItem]) -> String {
        items.map { "• \($0.text)" }.joined(separator: "\n")
    }

    fileprivate static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Single bullet line for an action item — selectable text plus a
/// right-click "Copy" affordance. Internal so both the detail view
/// and the rename sheet share the exact row layout.
private struct ActionItemRow: View {
    let text: String
    let alignment: Alignment
    let multiline: TextAlignment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            // Selectable so the user can drag-select the row's text;
            // right-click surfaces a one-click "Copy" for the whole
            // item (the most common ask — paste it into a TODO list).
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment)
                .multilineTextAlignment(multiline)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy") {
                        AIOverviewSection.copyToPasteboard(text)
                    }
                }
        }
    }
}
