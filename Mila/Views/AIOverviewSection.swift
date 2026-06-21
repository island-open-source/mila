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
    /// Whether the per-block "Copy summary" / "Copy action items"
    /// header buttons are shown. The rename sheet keeps them (default
    /// `true`); the detail view hides them — it consolidates copy into
    /// two location-based buttons (Summary+Action-items up top, the
    /// transcript copy in the transcript area). The block's native
    /// right-click "Copy" stays in both places either way.
    var showsBlockCopyButtons: Bool = true

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
                    summaryView(summaryText)
                }
                if !items.isEmpty {
                    actionItemsView()
                }
            }
            .frame(maxWidth: .infinity, alignment: alignmentValue)
        }
    }

    private func summaryView(_ text: String) -> some View {
        VStack(alignment: sectionIsRTL ? .trailing : .leading, spacing: 4) {
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
                if showsBlockCopyButtons, !text.isEmpty {
                    // One-click copy of the whole summary. The selectable
                    // text + context menu stay; a visible button just makes
                    // "grab the summary" obvious (matches the transcript's
                    // Copy button). Hidden in the detail view (which copies
                    // summary + action items from the header button) but
                    // kept in the rename sheet.
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
                // Render with structure: a single run-on paragraph (the
                // live rolling summary) becomes one bullet per sentence so
                // it reads as a few lines like the live pane; an already
                // multi-line markdown block is kept as-is. Inline markdown
                // (**bold** etc.) renders. `.leading` + layoutDirection
                // keeps Hebrew right-aligned with bullets on the right.
                Text(Self.summaryAttributed(text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .environment(\.layoutDirection, sectionIsRTL ? .rightToLeft : .leftToRight)
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
                    .frame(maxWidth: .infinity, alignment: sectionIsRTL ? .trailing : .leading)
                    .multilineTextAlignment(sectionIsRTL ? .trailing : .leading)
            }
        }
    }

    private func actionItemsView() -> some View {
        // One combined bullet line per item, joined into a SINGLE Text so
        // the whole list is drag-selectable / copyable at once (the old
        // per-item Text views couldn't be selected together). Non-breaking
        // space after the bullet keeps "•" glued to its line on wrap.
        let combined = items.map { "•\u{00A0}\($0.text)" }.joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Action items", systemImage: "checklist")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer(minLength: 8)
                if showsBlockCopyButtons {
                    // Copies every item as a bulleted block in one click.
                    // Hidden in the detail view (consolidated into the
                    // header's summary + action-items copy button) but kept
                    // in the rename sheet.
                    Button {
                        AIOverviewSection.copyToPasteboard(Self.actionItemsText(items))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy action items")
                    .accessibilityIdentifier("detail.actionItems.copy")
                }
            }
            // Single selectable block. `\.layoutDirection` drives the base
            // direction so the bullets land on the correct (right) side for
            // Hebrew. With layoutDirection set, the alignment MUST be
            // `.leading` (which mirrors to the right under RTL) — using
            // `.trailing` here too double-flipped and pushed Hebrew action
            // items to the LEFT, which was the bug. Let layoutDirection do
            // the mirroring exactly once.
            Text(combined)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .environment(\.layoutDirection, sectionIsRTL ? .rightToLeft : .leftToRight)
                .contextMenu {
                    Button("Copy") {
                        AIOverviewSection.copyToPasteboard(Self.actionItemsText(items))
                    }
                }
        }
    }

    /// All action items as a bulleted plain-text block, for one-click copy.
    fileprivate static func actionItemsText(_ items: [ActionItem]) -> String {
        items.map { "• \($0.text)" }.joined(separator: "\n")
    }

    /// Turn a stored summary into a few readable lines. The LLM emits
    /// either a short run-on paragraph (the live rolling summary) or a
    /// multi-line markdown block (the one-shot summarizer). A paragraph
    /// with no line breaks is split into one bullet per sentence so it
    /// reads as a few lines — matching the live recording pane — while a
    /// block that already has line structure is kept as-is. Inline
    /// markdown (`**bold**` etc.) is rendered; `\n` and literal "- " are
    /// preserved.
    static func summaryAttributed(_ raw: String) -> AttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmed.contains("\n") {
            body = trimmed
        } else {
            // Proper sentence segmentation via Foundation's tokenizer.
            // A naive split on bare ".!?" mangled "3.30 p.m.", "v2.0",
            // "acme.com", "https://…" into garbled mid-token bullets;
            // `.bySentences` keeps those intact.
            var sentences: [String] = []
            trimmed.enumerateSubstrings(in: trimmed.startIndex..<trimmed.endIndex,
                                        options: [.bySentences, .localized]) { sub, _, _, _ in
                let s = (sub ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
            }
            body = sentences.count > 1
                ? sentences.map { "•\u{00A0}\($0)" }.joined(separator: "\n")
                : trimmed
        }
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: body, options: opts)) ?? AttributedString(body)
    }

    fileprivate static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
