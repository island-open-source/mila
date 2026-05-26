import Foundation

/// Translation of the diarizer's raw `SPEAKER_00` / `SPEAKER_01` /…
/// identifiers into a label the user actually wants to see — `Speaker A`
/// in English, `דובר א׳` in Hebrew.
///
/// The raw labels stay in the internal data model (segment metadata,
/// SRT exports, post-recording sidecar text) because they're stable
/// across runs and tooling outside Mila (pyannote, third-party
/// re-clustering scripts) expects them. The conversion only happens
/// at display time and when feeding text to the LLM, so the LLM sees
/// the same labels the user sees and emits them back the same way.
extension String {
    func friendlySpeakerLabel(language: String) -> String {
        guard self.hasPrefix("SPEAKER_") else { return self }
        let suffix = self.dropFirst("SPEAKER_".count)
        guard let n = Int(suffix), n >= 0 else { return self }
        switch language {
        case "he":
            return "דובר \(hebrewOrdinal(n))"
        default:
            return "Speaker \(latinLetter(n))"
        }
    }

    private func latinLetter(_ index: Int) -> String {
        if index < 26 {
            let scalar = UnicodeScalar(UInt8(0x41) + UInt8(index))
            return String(Character(scalar))
        }
        // Wrap around: AA, BB, ... beyond the 26th speaker (extremely
        // unlikely in any real call). Keeps the helper total without
        // an arbitrary cap.
        let letter = String(Character(UnicodeScalar(UInt8(0x41) + UInt8(index % 26))))
        return letter + "\(index / 26 + 1)"
    }

    /// Hebrew "ordinal" letters: א׳, ב׳, ג׳ … Falls back to a numeric
    /// suffix beyond the 22-letter alphabet because we don't try to
    /// build multi-letter Hebrew sequences — anyone hitting that case
    /// has bigger problems than a label format.
    private func hebrewOrdinal(_ index: Int) -> String {
        let letters = ["א", "ב", "ג", "ד", "ה", "ו", "ז", "ח", "ט", "י",
                       "כ", "ל", "מ", "נ", "ס", "ע", "פ", "צ", "ק", "ר",
                       "ש", "ת"]
        if index < letters.count {
            return "\(letters[index])׳"
        }
        return "\(index + 1)"
    }
}
