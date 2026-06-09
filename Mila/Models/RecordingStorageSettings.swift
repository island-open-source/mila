import Foundation
import Combine

/// User-configurable destination for new recordings + the per-recording
/// metadata sidecars (`recordings.json`, `folders.json`, `.txt` transcripts,
/// `.srt` subtitles, the `.wav` itself). When unset, recordings live in the
/// historical default at `~/Library/Application Support/Mila/Recordings`.
///
/// The chosen path is persisted as a **security-scoped bookmark** rather
/// than a raw POSIX string. Two reasons:
///   1. Bookmarks survive the target folder being moved/renamed (until the
///      bookmark goes "stale", at which point we offer to refresh it).
///   2. Even though Mila currently ships unsandboxed
///      (`com.apple.security.app-sandbox = false`), the
///      `com.apple.security.files.user-selected.read-write` entitlement is
///      already declared. Using security-scoped bookmarks means the feature
///      keeps working without code changes if/when sandboxing is enabled —
///      otherwise the app would silently lose access to the chosen folder
///      on the next launch after sandbox-on.
///
/// Resolution semantics:
///   * No bookmark persisted -> `resolvedDirectory == nil` -> store falls
///     back to its default Application Support location.
///   * Bookmark resolves cleanly -> `resolvedDirectory` returns the URL,
///     and `startAccessing()` has already been called so callers can write
///     to it. The matching `stopAccessing()` runs on dealloc.
///   * Bookmark is stale or the directory is missing -> we clear the
///     persisted bookmark and behave as if it was never set. The user
///     sees the default location in Settings + can re-pick. We
///     deliberately do NOT keep showing a stale entry — silent fallback
///     is the only correct behaviour when the user removed the disk or
///     deleted the folder.
@MainActor
final class RecordingStorageSettings: ObservableObject {
    static let bookmarkKey = "storage.recordingsDirectoryBookmark"
    static let limitBytesKey = "storage.limitBytes"
    /// 5 GiB — generous for compressed (m4a) recordings (~20–30 MB/hour),
    /// so this is roughly 150+ hours before the cap bites.
    static let defaultLimitBytes: Int64 = 5 * 1024 * 1024 * 1024

    /// Hard cap on the recordings library size. New recordings are
    /// blocked once usage reaches this; existing/in-progress recordings
    /// are never touched. Persisted so the choice sticks across launches.
    @Published var limitBytes: Int64 {
        didSet {
            guard limitBytes != oldValue else { return }
            defaults.set(limitBytes, forKey: Self.limitBytesKey)
        }
    }

    /// Whole-GB view of `limitBytes` for the Settings stepper. Uses GiB
    /// (1024³) to match how Finder/macOS report sizes in this range.
    var limitGigabytes: Double {
        get { Double(limitBytes) / 1_073_741_824.0 }
        set { limitBytes = max(1, Int64((newValue * 1_073_741_824.0).rounded())) }
    }

    /// The currently-active user-selected recordings directory, or nil when
    /// the default is in effect. Published so the Settings UI re-renders
    /// the moment the user picks (or clears) a folder.
    @Published private(set) var customDirectory: URL?

    /// Set on stale-bookmark resolution so the Settings UI can show a
    /// "the folder you picked is no longer available — falling back to
    /// the default" badge without re-checking on every render.
    @Published private(set) var lastResolutionWasStale: Bool = false

    private let defaults: UserDefaults

    /// Tracks the security-scoped resource we've called
    /// `startAccessingSecurityScopedResource` on so we can pair it with
    /// the matching `stop` call on relocation / shutdown. Unsandboxed
    /// builds don't strictly need this, but the bookmark + start/stop
    /// pair is the right pattern and is what we'd be required to do
    /// under sandbox.
    private var accessingURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.limitBytesKey) as? Int {
            self.limitBytes = Int64(stored)
        } else {
            self.limitBytes = Self.defaultLimitBytes
        }
        resolveAndStartAccessing()
    }

    deinit {
        // Can't call MainActor-isolated stop from deinit; AppKit will
        // tear the process down anyway. Documented here to make the
        // intentional choice explicit.
    }

    /// Resolve the persisted bookmark into a URL. Idempotent — safe to
    /// call after `setDirectory` or `clearDirectory` to re-sync state.
    private func resolveAndStartAccessing() {
        // Stop any previous access first so we don't leak scope on the
        // outgoing URL.
        if let url = accessingURL {
            url.stopAccessingSecurityScopedResource()
            accessingURL = nil
        }
        customDirectory = nil
        lastResolutionWasStale = false

        guard let data = defaults.data(forKey: Self.bookmarkKey) else {
            return
        }
        var isStale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // Bookmark blob unreadable — drop it so we don't keep
            // failing on every launch.
            print("RecordingStorageSettings: failed to resolve bookmark: \(error)")
            defaults.removeObject(forKey: Self.bookmarkKey)
            return
        }
        if isStale {
            // The folder still exists at a different path; re-mint the
            // bookmark so future launches resolve cleanly. If re-minting
            // itself fails, treat the bookmark as gone.
            lastResolutionWasStale = true
            if let refreshed = try? resolved.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaults.set(refreshed, forKey: Self.bookmarkKey)
            } else {
                defaults.removeObject(forKey: Self.bookmarkKey)
                return
            }
        }
        // Confirm the folder is still readable before claiming it as
        // active — a bookmark to a missing folder resolves but `start`
        // returns true with a directory that doesn't exist on disk.
        let started = resolved.startAccessingSecurityScopedResource()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            if started { resolved.stopAccessingSecurityScopedResource() }
            defaults.removeObject(forKey: Self.bookmarkKey)
            return
        }
        accessingURL = resolved
        customDirectory = resolved
    }

    /// Persist a freshly-picked folder. Mints a security-scoped bookmark
    /// against the URL (NSOpenPanel hands us one already, so the security
    /// scope is implicit). Returns true on success — false means the
    /// bookmark couldn't be created and the previous selection is
    /// untouched.
    @discardableResult
    func setDirectory(_ url: URL) -> Bool {
        do {
            // NSOpenPanel returns a URL that's already in the
            // security-scoped sandbox for sandboxed apps; for our
            // unsandboxed build it returns a plain file URL but the
            // bookmark API still works.
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Self.bookmarkKey)
            resolveAndStartAccessing()
            return customDirectory != nil
        } catch {
            print("RecordingStorageSettings: failed to mint bookmark for \(url.path): \(error)")
            return false
        }
    }

    /// Clear the user override and fall back to the default location.
    func clearDirectory() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        resolveAndStartAccessing()
    }
}
