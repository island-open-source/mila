import Foundation
import AppKit
import OSLog

/// Bundles everything a support person would need to diagnose an issue
/// into a single zip the user can send by email / Slack / wherever.
///
/// The report is **opt-in and never auto-sent** — the user invokes it via
/// Help → "Save Diagnostic Report…", picks where to save the zip, and
/// reviews the contents themselves before forwarding. This keeps the
/// privacy contract simple: nothing leaves the machine unless the user
/// chose to share it.
///
/// Contents (see `report-manifest.txt` inside the zip for an authoritative
/// list):
///   - `manifest.txt`            — what's included + when it was generated
///   - `system-info.txt`         — macOS version, hardware, app version
///   - `logs/process.log`        — recent OSLog entries from this process
///   - `recordings.json`         — metadata (titles, durations, statuses)
///                                  but NOT transcript text or audio
///   - `folders.json`            — folder list (already metadata-only)
///   - `settings.json`           — UserDefaults keys under "diarization.",
///                                 "audio.", "llm.", "hotkeys.", etc.
///   - `diarization-health.txt`  — the last health-check result
///   - `crash-reports/`          — the 5 most recent .ips files matching
///                                 Mila / IslandWhisper / IvritWhisper
///                                 (historical names)
///
/// Things deliberately **NOT** included:
///   - Audio files (too big + sensitive)
///   - Transcript sidecar `.txt` files (sensitive)
///   - LLM CLI executables, model weights, etc.
@MainActor
enum DiagnosticReporter {

    /// Build the report into a temp directory and return the URL of the
    /// produced .zip. Caller is responsible for moving it to a user-chosen
    /// final destination + deleting the temp dir.
    static func buildReport(store: RecordingStore,
                            diarization: DiagnosticSnapshotProvider?) async throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-diagnostic-\(UUID().uuidString)", isDirectory: true)
        let payload = tmpRoot.appendingPathComponent("Mila-DiagnosticReport-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)

        try writeManifest(at: payload, stamp: stamp)
        try writeSystemInfo(at: payload)
        try writeRecordingsMetadata(at: payload, store: store)
        try writeFolders(at: payload, store: store)
        try writeSettings(at: payload)
        try await writeLogs(at: payload)
        try writeCrashReports(at: payload)
        try await writeDiarizationHealth(at: payload, provider: diarization)

        let zipURL = tmpRoot.appendingPathComponent(payload.lastPathComponent + ".zip")
        try await zipDirectory(payload, to: zipURL)
        return zipURL
    }

    /// Save the report to a user-chosen location via NSSavePanel. Returns
    /// the final URL on success (or nil if the user cancelled).
    static func saveReportInteractively(store: RecordingStore,
                                        diarization: DiagnosticSnapshotProvider?) async throws -> URL? {
        let zipURL = try await buildReport(store: store, diarization: diarization)
        defer {
            // Best-effort cleanup of the temp staging dir. We leave the zip
            // itself alone — the user may have copied it to a final dest.
            try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent())
        }

        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Report"
        panel.nameFieldStringValue = zipURL.lastPathComponent
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else {
            return nil
        }
        // Replace any existing file at the destination — the user picked
        // the location knowing the consequences.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: zipURL, to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        return destination
    }

    // MARK: - Individual sections

    private static func writeManifest(at dir: URL, stamp: String) throws {
        let body = """
        Mila Diagnostic Report
        Generated: \(stamp)

        Files in this archive:
          system-info.txt        macOS + hardware + app version
          logs/process.log       Recent OSLog entries from this run
          recordings.json        Recording metadata (no audio, no transcripts)
          folders.json           User-created folder list
          settings.json          App preferences (no auth tokens)
          diarization-health.txt Speaker-detection pipeline status
          crash-reports/         Up to 5 most recent .ips files

        Things NOT included:
          - Audio files (.wav)
          - Transcript text (.txt sidecars)
          - LLM CLI executables or output
          - HuggingFace / cloud auth tokens

        Send this zip to whoever is helping you diagnose the issue.
        """
        try body.write(to: dir.appendingPathComponent("manifest.txt"),
                       atomically: true, encoding: .utf8)
    }

    private static func writeSystemInfo(at dir: URL) throws {
        let info = ProcessInfo.processInfo
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let body = """
        App:              Mila
        Bundle ID:        \(bundle.bundleIdentifier ?? "?")
        Version:          \(version) (build \(build))
        macOS:            \(info.operatingSystemVersionString)
        Hardware model:   \(hardwareModel())
        Locale:           \(Locale.current.identifier)
        Time zone:        \(TimeZone.current.identifier)
        Physical memory:  \(info.physicalMemory / 1_048_576) MB
        Processor count:  \(info.processorCount)
        Active CPU count: \(info.activeProcessorCount)
        Generated:        \(Date())
        """
        try body.write(to: dir.appendingPathComponent("system-info.txt"),
                       atomically: true, encoding: .utf8)
    }

    private static func writeRecordingsMetadata(at dir: URL, store: RecordingStore) throws {
        // Strip transcript text + segment text — we want counts + sizes, not
        // anything the user might consider private.
        let scrubbed: [[String: Any]] = store.recordings.map(scrubbedDict(for:))
        let summary: [String: Any] = [
            "total_recordings": store.recordings.count,
            "non_trashed": store.recordings.filter { !$0.isTrashed }.count,
            "trashed": store.recordings.filter { $0.isTrashed }.count,
            "by_status": Dictionary(grouping: store.recordings, by: { $0.status.rawValue })
                .mapValues { $0.count },
            "by_source": Dictionary(grouping: store.recordings, by: { $0.source.rawValue })
                .mapValues { $0.count }
        ]
        let payload: [String: Any] = [
            "summary": summary,
            "recordings": scrubbed
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("recordings.json"))
    }

    /// Per-recording metadata dictionary. Split out from
    /// `writeRecordingsMetadata` so the compiler can type-check it on its
    /// own (a single dict literal of this size triggered "unable to
    /// type-check in reasonable time").
    private static func scrubbedDict(for rec: Recording) -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["id"] = rec.id.uuidString
        dict["title_length"] = rec.title.count
        dict["createdAt"] = ISO8601DateFormatter().string(from: rec.createdAt)
        dict["duration_seconds"] = rec.duration
        dict["source"] = rec.source.rawValue
        dict["app_name"] = rec.appName ?? NSNull()
        dict["language"] = rec.language
        dict["model_name"] = rec.modelName ?? NSNull()
        dict["status"] = rec.status.rawValue
        dict["is_trashed"] = rec.isTrashed
        dict["folder"] = rec.folder ?? NSNull()
        dict["segment_count"] = rec.segments.count
        dict["full_text_length"] = rec.fullText.count
        return dict
    }

    private static func writeFolders(at dir: URL, store: RecordingStore) throws {
        let data = try JSONSerialization.data(withJSONObject: store.folders,
                                              options: [.prettyPrinted])
        try data.write(to: dir.appendingPathComponent("folders.json"))
    }

    private static func writeSettings(at dir: URL) throws {
        // Whitelist of UserDefaults key prefixes we know are Mila-owned.
        // Avoids leaking unrelated app or system defaults into the zip.
        let prefixes = ["diarization.", "audio.", "llm.", "hotkeys.",
                        "home.", "rename.", "recordingLanguage", "selectedModelName"]
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        var scoped: [String: Any] = [:]
        for (key, value) in defaults {
            guard prefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            // Don't leak anything that looks like a secret. There aren't
            // supposed to be any, but a future change might add one.
            if key.lowercased().contains("token") || key.lowercased().contains("secret")
                || key.lowercased().contains("apikey") || key.lowercased().contains("password") {
                scoped[key] = "<redacted>"
            } else {
                scoped[key] = sanitizedValue(value)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: scoped,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("settings.json"))
    }

    /// JSON only encodes specific types — translate the catch-alls we get
    /// from `UserDefaults` into something `JSONSerialization` accepts.
    private static func sanitizedValue(_ value: Any) -> Any {
        switch value {
        case let v as String: return v
        case let v as NSNumber: return v
        case let v as Bool: return v
        case let v as Date: return ISO8601DateFormatter().string(from: v)
        case let v as Data: return "<\(v.count) bytes>"
        case let v as [Any]: return v.map(sanitizedValue)
        case let v as [String: Any]: return v.mapValues(sanitizedValue)
        default: return String(describing: value)
        }
    }

    private static func writeLogs(at dir: URL) async throws {
        let logsDir = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // OSLogStore with scope: .currentProcessIdentifier requires no
        // entitlement; it returns only this process's recent log entries.
        // We capture the last hour by default — long enough to catch the
        // run-up to whatever the user is reporting, short enough to keep
        // the zip small.
        let body: String
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-3600))
            let entries = try store.getEntries(at: position)
            var lines: [String] = []
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                lines.append("[\(logEntry.date.formatted(.iso8601))] [\(logEntry.subsystem)] [\(logEntry.category)] \(logEntry.composedMessage)")
            }
            body = lines.isEmpty
                ? "(no OSLog entries captured — Mila uses plain print() statements which don't land in OSLogStore. See system Console.app and filter on the Mila process for richer logs.)"
                : lines.joined(separator: "\n")
        } catch {
            body = "(OSLogStore unavailable: \(error.localizedDescription))"
        }
        try body.write(to: logsDir.appendingPathComponent("process.log"),
                       atomically: true, encoding: .utf8)
    }

    /// Copy up to 5 most-recent crash reports matching Mila or the
    /// historical IslandWhisper / IvritWhisper names. macOS writes these
    /// to `~/Library/Logs/DiagnosticReports/` as `.ips` (Apple's JSON
    /// crash format).
    private static func writeCrashReports(at dir: URL) throws {
        let fm = FileManager.default
        let logsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let destDir = dir.appendingPathComponent("crash-reports", isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        guard let contents = try? fm.contentsOfDirectory(at: logsDir,
                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else {
            try "(no crash reports directory found at \(logsDir.path))"
                .write(to: destDir.appendingPathComponent("README.txt"),
                       atomically: true, encoding: .utf8)
            return
        }
        let matches = contents.filter { url in
            let name = url.lastPathComponent
            return (name.hasPrefix("Mila") || name.hasPrefix("IslandWhisper") || name.hasPrefix("IvritWhisper"))
                && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
        }
        let sorted = matches.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for url in sorted.prefix(5) {
            try? fm.copyItem(at: url, to: destDir.appendingPathComponent(url.lastPathComponent))
        }
        if sorted.isEmpty {
            try "(no Mila / IslandWhisper / IvritWhisper crash reports found in \(logsDir.path))"
                .write(to: destDir.appendingPathComponent("README.txt"),
                       atomically: true, encoding: .utf8)
        }
    }

    private static func writeDiarizationHealth(at dir: URL,
                                               provider: DiagnosticSnapshotProvider?) async throws {
        let body: String
        if let provider {
            body = await provider.diagnosticSnapshot()
        } else {
            body = "(diarization provider not wired into the diagnostic reporter)"
        }
        try body.write(to: dir.appendingPathComponent("diarization-health.txt"),
                       atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// Use the system `ditto` binary to zip the staging directory.
    /// `ditto -c -k --sequesterRsrc --keepParent` produces a flat .zip
    /// archive identical in shape to what Finder's "Compress" command
    /// makes — most familiar to non-technical recipients.
    static func zipDirectory(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [
                "-c", "-k",
                "--sequesterRsrc",
                "--keepParent",
                source.path,
                destination.path
            ]
            let errPipe = Pipe()
            process.standardError = errPipe
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                throw NSError(domain: "DiagnosticReporter", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "ditto failed: \(err)"])
            }
        }.value
    }
}

/// Decoupling seam — the reporter doesn't depend on DiarizationSettings
/// directly so it can be unit-tested without spinning up the Python
/// pipeline. Whatever the app passes in just has to be able to render a
/// status string.
protocol DiagnosticSnapshotProvider: Sendable {
    func diagnosticSnapshot() async -> String
}
