import Foundation
import AppKit

/// One-shot self-relocator that handles the IslandWhisper → Mila bundle
/// rename. Sparkle's in-place update replaces the running app's
/// *contents* but keeps the existing bundle path, so an install that
/// auto-updated from IslandWhisper v1.3.x ends up at
/// `/Applications/IslandWhisper.app/` even though the app inside now
/// identifies as Mila. This relocator detects that mismatch on launch
/// and, with the user's consent, moves the bundle to
/// `/Applications/Mila.app/` and relaunches.
///
/// Why a helper script rather than an in-process `FileManager.moveItem`:
/// macOS refuses to move a running app bundle (the executable is in
/// use). The helper waits for our process to exit first, then mv's the
/// bundle and reopens it from the new location.
@MainActor
enum BundleRelocator {
    /// UserDefaults key tracking whether the user already dismissed the
    /// rename prompt. We don't want to nag on every launch.
    private static let skippedKey = "bundle.relocate.islandwhisper.skipped"

    /// Detect the mismatch and present a one-tap rename dialog. Safe to
    /// call from anywhere early in app launch — bails out cheaply when
    /// there's nothing to do.
    static func relocateIfNeeded() {
        guard let mismatch = detectMismatch() else { return }
        // Respect a prior skip — the user explicitly said "not now",
        // we shouldn't keep prompting.
        if UserDefaults.standard.bool(forKey: skippedKey) {
            return
        }
        promptAndRelocate(from: mismatch.currentURL, to: mismatch.targetURL)
    }

    // MARK: - Detection

    private struct Mismatch {
        let currentURL: URL
        let targetURL: URL
    }

    /// Returns the source + destination URLs if the bundle is installed
    /// under /Applications with a stale name. nil means nothing to do.
    private static func detectMismatch() -> Mismatch? {
        let bundleURL = Bundle.main.bundleURL
        let currentName = bundleURL.lastPathComponent
        let bundleName = (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "Mila"
        let expectedName = bundleName + ".app"
        guard currentName != expectedName else { return nil }

        // Only auto-relocate when the bundle lives in one of the
        // standard Applications directories. We don't want to surprise-
        // move bundles that the user dragged into a custom location
        // (~/Downloads, a Dropbox folder, etc.) — they put it there on
        // purpose.
        let parent = bundleURL.deletingLastPathComponent()
        let standardApps = ["/Applications", "/Applications/Utilities"]
        let userApps = (FileManager.default.urls(for: .applicationDirectory,
                                                  in: .userDomainMask).first?.path) ?? "/Users/\(NSUserName())/Applications"
        guard standardApps.contains(parent.path) || parent.path == userApps else {
            return nil
        }

        let target = parent.appendingPathComponent(expectedName)
        // If a Mila.app already exists at the destination, don't trash
        // it. This guards against the case where the user manually
        // downloaded a fresh Mila.app and ALSO has an old IslandWhisper
        // install — they need to resolve that themselves.
        if FileManager.default.fileExists(atPath: target.path) {
            return nil
        }

        return Mismatch(currentURL: bundleURL, targetURL: target)
    }

    // MARK: - Prompt + relocate

    /// Shows a small NSAlert with two options:
    ///   - "Rename and Relaunch" (default): perform the relocation.
    ///   - "Not Now": persist the skip flag and let the user run with
    ///     a mismatched name. Future launches won't prompt.
    private static func promptAndRelocate(from currentURL: URL, to targetURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Rename app to Mila.app?"
        alert.informativeText = "The app is installed at \(currentURL.lastPathComponent) from a previous version. Renaming the bundle to \(targetURL.lastPathComponent) keeps Finder and Spotlight in sync with the app's new name. The app will quit and relaunch."
        alert.alertStyle = .informational
        let renameButton = alert.addButton(withTitle: "Rename and Relaunch")
        renameButton.keyEquivalent = "\r"   // default
        let skipButton = alert.addButton(withTitle: "Not Now")
        skipButton.keyEquivalent = "\u{1b}" // escape

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            performRelocation(from: currentURL, to: targetURL)
        default:
            UserDefaults.standard.set(true, forKey: skippedKey)
        }
    }

    /// Spawn a detached `/bin/bash` helper that waits for this process
    /// to exit, mv's the bundle, refreshes LaunchServices, and reopens
    /// the app from its new location. Then quits the current process.
    private static func performRelocation(from currentURL: URL, to targetURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let oldPath = currentURL.path
        let newPath = targetURL.path

        // The helper script:
        //   1. Polls `kill -0 $PID` until our process is gone. `kill -0`
        //      only sends signal 0 (a no-op); it succeeds iff the
        //      process exists, so a non-zero exit means we're gone.
        //   2. Tiny sleep to let macOS release any lingering handles.
        //   3. mv the bundle. POSIX rename within the same filesystem;
        //      no copy fallback needed in /Applications.
        //   4. lsregister so Finder / LaunchPad / Spotlight pick up the
        //      new path immediately rather than after the next reindex.
        //   5. open the new bundle.
        // Quoting via printf %q would be more correct in general but
        // /Applications paths are well-known and safe; just single-
        // quote them.
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        sleep 0.3
        /bin/mv '\(oldPath)' '\(newPath)'
        '\(lsregister)' -f '\(newPath)' 2>/dev/null || true
        /usr/bin/open '\(newPath)'
        """

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = ["-c", script]
        do {
            try helper.run()
        } catch {
            // Couldn't spawn — surface a fallback alert and keep
            // running under the old name. The user can rename manually.
            let alert = NSAlert()
            alert.messageText = "Could not start the renamer"
            alert.informativeText = "Mila tried to rename its bundle to Mila.app but couldn't launch the helper (\(error.localizedDescription)). You can rename /Applications/\(currentURL.lastPathComponent) to Mila.app in Finder yourself."
            alert.runModal()
            return
        }

        // Hard-exit rather than NSApp.terminate to skip the graceful-
        // shutdown sequence (whisper.cpp tear-down etc). The helper
        // waits on our PID via `kill -0`; the faster we exit, the less
        // visible the gap between quit and relaunch.
        exit(0)
    }
}
