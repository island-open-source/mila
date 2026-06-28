import Foundation
import Combine

/// User settings for iPhone Voice Memos folder integration. Persists which
/// Voice Memos folders Mila watches + auto-transcribes. Follows the same
/// shape as `DiarizationSettings`: `@Published` properties that write through
/// to namespaced `UserDefaults` keys, with an injectable `defaults` suite so
/// tests stay isolated from the user's real preferences.
///
/// Folders are keyed by their stable `ZFOLDER.ZUUID` (not their display name,
/// which the user can rename). The unfiled bucket — recordings with no folder,
/// usually the bulk of a library — is tracked by a separate flag.
@MainActor
final class VoiceMemosSettings: ObservableObject {

    /// Master switch. Off by default: Voice Memos sync reads another app's
    /// data and kicks off bulk transcription, so it's strictly opt-in.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    /// `ZUUID`s of the Voice Memos folders the user chose to watch.
    @Published var selectedFolderUUIDs: Set<String> {
        didSet {
            defaults.set(Array(selectedFolderUUIDs).sorted(), forKey: Keys.folderUUIDs)
        }
    }

    /// Whether to also watch the unfiled bucket (`ZFOLDER IS NULL`).
    @Published var includeUnfiled: Bool {
        didSet { defaults.set(includeUnfiled, forKey: Keys.includeUnfiled) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "voiceMemos.enabled"
        static let folderUUIDs = "voiceMemos.folderUUIDs"
        static let includeUnfiled = "voiceMemos.includeUnfiled"
    }

    /// Skip accidental sub-`minDurationSeconds` taps during bulk import. Voice
    /// Memos libraries are full of 1–2s pocket recordings; transcribing them
    /// is pure noise. Not user-configurable — a sensible fixed floor.
    static let minDurationSeconds: Double = 3.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        let stored = defaults.stringArray(forKey: Keys.folderUUIDs) ?? []
        self.selectedFolderUUIDs = Set(stored)
        self.includeUnfiled = defaults.bool(forKey: Keys.includeUnfiled)
    }

    /// True when the user has actually picked something to watch — gates the
    /// importer so enabling the feature without choosing a folder is a no-op
    /// rather than silently importing nothing (or everything).
    var hasSelection: Bool {
        !selectedFolderUUIDs.isEmpty || includeUnfiled
    }

    /// Convenience toggle used by the folder multiselect in Settings.
    func setFolder(_ uuid: String, selected: Bool) {
        if selected {
            selectedFolderUUIDs.insert(uuid)
        } else {
            selectedFolderUUIDs.remove(uuid)
        }
    }
}
