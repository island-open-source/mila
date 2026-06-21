import Foundation

/// The content shown in the pre-update "What's New" popup.
///
/// The available version's release notes can ONLY come from the Sparkle
/// appcast item — the *installed* app can't carry the not-yet-released
/// version's notes locally. So `highlights` are parsed from the appcast
/// item's HTML release-notes description (`SUAppcastItem.itemDescription`).
/// Per-release content is therefore driven by whatever release notes the
/// developer writes into each `<description>` of the published appcast.
///
/// This type is intentionally a plain value with no Sparkle dependency so
/// it can be unit-tested in isolation and constructed from UI-test fixtures.
struct WhatsNewUpdate: Equatable, Identifiable {
    /// Human-readable display version, e.g. "1.9.0". Drives the popup title
    /// ("What's New in Mila 1.9.0") and the "last seen" persistence key.
    let displayVersion: String
    /// Short bulleted highlights extracted from the appcast release notes.
    /// Capped + de-noised by `parseHighlights` so the popup stays scannable.
    let highlights: [String]
    /// The full release-notes HTML/text (used as a fallback body when no
    /// bullet-like highlights could be parsed out).
    let fullNotes: String

    /// Stable identity for SwiftUI `.sheet(item:)` — the version string is
    /// unique per advertised update.
    var id: String { displayVersion }

    /// Max number of highlight bullets we surface. Beyond this the popup
    /// stops being an enticement and starts being a changelog.
    static let maxHighlights = 6

    init(displayVersion: String, highlights: [String], fullNotes: String = "") {
        self.displayVersion = displayVersion
        self.highlights = highlights
        self.fullNotes = fullNotes
    }

    /// Build a popup model from an appcast item's display version + the raw
    /// release-notes string (typically `SUAppcastItem.itemDescription`,
    /// which Sparkle exposes as the `<description>` HTML).
    init(displayVersion: String, releaseNotesHTML: String?) {
        self.displayVersion = displayVersion
        let notes = releaseNotesHTML ?? ""
        self.fullNotes = Self.plainText(from: notes)
        self.highlights = Self.parseHighlights(from: notes)
    }

    /// Pull short, scannable highlight lines out of an appcast
    /// release-notes blob. Handles the two shapes developers actually
    /// write in a `<description>`:
    ///   1. An HTML `<ul><li>…</li></ul>` list (the common Sparkle case).
    ///   2. Plain text with one highlight per line, optionally prefixed
    ///      with a bullet glyph or "- " / "* ".
    /// Falls back to the first few non-empty sentences if neither shape
    /// is present, so a prose-only release note still shows *something*.
    static func parseHighlights(from notes: String) -> [String] {
        guard !notes.isEmpty else { return [] }

        // 1. HTML <li> items take precedence — that's the structured intent.
        let liItems = listItems(in: notes)
        if !liItems.isEmpty {
            return Array(liItems.prefix(maxHighlights))
        }

        // 2. Otherwise treat the (de-tagged) text line-by-line. Keep lines
        //    that look like bullets, or — if nothing is bulleted — the
        //    first few non-empty lines.
        let plain = plainText(from: notes)
        let lines = plain
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let bulletPrefixes = ["- ", "* ", "• ", "– ", "· "]
        let bulleted = lines.compactMap { line -> String? in
            for p in bulletPrefixes where line.hasPrefix(p) {
                return String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        if !bulleted.isEmpty {
            return Array(bulleted.prefix(maxHighlights))
        }

        // 3. Prose fallback: first few non-empty lines verbatim.
        return Array(lines.prefix(maxHighlights))
    }

    /// Extract the inner text of every `<li>…</li>` element, in order,
    /// with their own inner tags stripped and whitespace collapsed.
    private static func listItems(in html: String) -> [String] {
        var items: [String] = []
        let lower = html.lowercased()
        var searchStart = lower.startIndex
        while let openRange = lower.range(of: "<li", range: searchStart..<lower.endIndex) {
            // Find the end of the opening tag (the '>').
            guard let openTagEnd = lower.range(of: ">", range: openRange.upperBound..<lower.endIndex) else { break }
            // Find the matching </li>.
            guard let closeRange = lower.range(of: "</li>", range: openTagEnd.upperBound..<lower.endIndex) else { break }
            // Map the lowercased indices back onto the original string —
            // String indices are shared across `lower`/`html` only when the
            // case-fold is 1:1; to be safe we slice the original by offset.
            let startOffset = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: openTagEnd.upperBound))
            let endOffset = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: closeRange.lowerBound))
            let inner = String(html[startOffset..<endOffset])
            let text = plainText(from: inner)
            if !text.isEmpty { items.append(text) }
            searchStart = closeRange.upperBound
        }
        return items
    }

    /// Strip HTML tags, decode the handful of common entities, and collapse
    /// runs of whitespace. Deliberately dependency-free (no NSAttributedString
    /// HTML import, which is main-thread-only and flaky under test).
    static func plainText(from html: String) -> String {
        var text = ""
        var insideTag = false
        for ch in html {
            switch ch {
            case "<": insideTag = true
            case ">": insideTag = false
            default:
                if !insideTag { text.append(ch) }
            }
        }
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Collapse interior whitespace runs while preserving newlines so the
        // line-based highlight parser still sees one highlight per line.
        let collapsedLines = text
            .components(separatedBy: .newlines)
            .map { line -> String in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .joined(separator: " ")
            }
        return collapsedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Decides whether the pre-update "What's New" popup should be shown for a
/// given available version, and remembers which version the user has
/// already been shown so we don't nag them on every scheduled appcast poll.
///
/// Pure logic, isolated from Sparkle and SwiftUI so it's unit-testable.
/// The "last seen" version is persisted in `UserDefaults` under a namespaced
/// key (matching the project's settings-persistence convention).
struct WhatsNewGate {
    static let lastSeenKey = "whatsNew.lastSeenVersion"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The version we most recently showed the popup for (or nil if never).
    var lastSeenVersion: String? {
        defaults.string(forKey: Self.lastSeenKey)
    }

    /// True iff we should present the popup for `availableVersion`. We show
    /// it whenever the available version differs from the last one we showed
    /// — Sparkle has already decided this is a NEWER valid update before it
    /// hands us the item, so a string inequality is the right gate here
    /// (re-deriving "is newer" would just duplicate Sparkle's own compare).
    func shouldShow(availableVersion: String) -> Bool {
        let trimmed = availableVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != lastSeenVersion
    }

    /// Record that the user has now seen the popup for `version`, so it
    /// isn't shown again for the same version on the next poll.
    func markSeen(version: String) {
        defaults.set(version, forKey: Self.lastSeenKey)
    }
}
