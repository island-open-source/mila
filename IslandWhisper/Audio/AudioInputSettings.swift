import Foundation
import Combine

/// User's choice of input device for new recordings. When `preferredUID` is
/// nil we let `AudioDeviceManager.preferredInputDevice()` pick automatically
/// (current system default, falling back to built-in). When set, we pin to
/// that exact device — useful for users who keep a virtual mic (e.g. Krisp)
/// as their system default but want IslandWhisper to read straight from the
/// hardware mic.
@MainActor
final class AudioInputSettings: ObservableObject {
    /// kAudioDevicePropertyDeviceUID of the user's pinned input, or nil for
    /// "follow the system default".
    @Published var preferredUID: String? {
        didSet {
            guard preferredUID != oldValue else { return }
            if let preferredUID {
                defaults.set(preferredUID, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    private let defaults: UserDefaults
    private static let key = "audio.input.preferredUID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferredUID = defaults.string(forKey: Self.key)
    }
}
