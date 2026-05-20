import Foundation
import TranscriptionCore

enum TranscriptFormatter {

    /// Plain-text rendering of `segments` suitable for the clipboard or for
    /// piping into an LLM prompt. When any segment carries a speaker label
    /// (diarization ran), each turn is prefixed `SPEAKER_XX: ` and
    /// consecutive segments from the same speaker collapse into one
    /// paragraph. When no segment has a speaker, falls back to `fallback`
    /// — the trimmed full-text join the rest of the app stores.
    ///
    /// Matches the SRT exporter's prefix format so the clipboard text and
    /// the on-disk `.srt` use the same speaker labels.
    static func plainText(segments: [TranscriptSegment], fallback: String) -> String {
        guard segments.contains(where: { $0.speaker != nil }) else { return fallback }

        var lines: [String] = []
        var currentSpeaker: String?? = .none
        var buffer = ""

        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = seg.speaker

            if currentSpeaker == .none {
                currentSpeaker = .some(speaker)
                buffer = text
                continue
            }

            if currentSpeaker == .some(speaker) {
                buffer += " " + text
            } else {
                lines.append(format(speaker: currentSpeaker.flatMap { $0 }, text: buffer))
                currentSpeaker = .some(speaker)
                buffer = text
            }
        }

        if !buffer.isEmpty {
            lines.append(format(speaker: currentSpeaker.flatMap { $0 }, text: buffer))
        }

        return lines.joined(separator: "\n")
    }

    private static func format(speaker: String?, text: String) -> String {
        guard let speaker else { return text }
        return "\(speaker): \(text)"
    }
}
