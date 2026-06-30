import Foundation
import SQLite3
import Darwin

/// Read-only reader over the iPhone Voice Memos library that iCloud syncs
/// to this Mac. Everything lives in a Core Data SQLite store inside the
/// Voice Memos group container:
///
///   ~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/
///       CloudRecordings.db        (+ -wal / -shm siblings while in use)
///       20250509 121919-XXXX.m4a  (the audio files, named by ZPATH)
///
/// The schema is private and shifts between macOS releases, so every column
/// this reader depends on is resolved at runtime via `PRAGMA table_info`
/// rather than hard-coded — if Apple renames or drops one we degrade to an
/// empty result instead of crashing. We open the DB **read-only** and never
/// write to it; `voicememod` owns it and keeps it in WAL mode, so concurrent
/// reads are safe while the daemon syncs new recordings in.
///
/// This type is a stateless value: each call opens, queries, and closes its
/// own connection, so it's safe to use from any thread / `Task.detached`.
struct VoiceMemosLibrary {

    /// Directory holding `CloudRecordings.db` and the audio files. Audio
    /// paths from the DB (`ZPATH`) are resolved relative to this.
    let recordingsDirectory: URL

    init(recordingsDirectory: URL = VoiceMemosLibrary.defaultRecordingsDirectory) {
        self.recordingsDirectory = recordingsDirectory
    }

    /// The standard on-disk location of the synced Voice Memos library.
    static var defaultRecordingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent("group.com.apple.VoiceMemos.shared")
            .appendingPathComponent("Recordings")
    }

    var databaseURL: URL {
        recordingsDirectory.appendingPathComponent("CloudRecordings.db")
    }

    /// `databaseURL.path` with the home directory shortened to `~`. The
    /// absolute form embeds the macOS account name, so this is the variant
    /// safe to log at `.public` — it keeps full diagnostic value (which path
    /// Mila probed) without leaking a user identifier into the unified log.
    /// See issue #45.
    var databaseDisplayPath: String {
        (databaseURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// `recordingsDirectory.path` with the home directory shortened to `~`;
    /// the `.public`-safe counterpart used by the watcher-started log line.
    /// See `databaseDisplayPath`.
    var recordingsDirectoryDisplayPath: String {
        (recordingsDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    /// Why the Voice Memos library can — or can't — be read right now.
    ///
    /// A bare `fileExists` check can't tell "the user has no synced library"
    /// from "macOS denied us access": Mila is **not** sandboxed, so reading
    /// another app's group container needs Full Disk Access (or a
    /// Files-and-Folders grant). When that's missing, the OS blocks the path
    /// and the probe fails with `EPERM`/`EACCES` rather than `ENOENT`.
    /// Classifying the two lets the importer log the difference and the
    /// Settings tab show an actionable hint instead of a misleading
    /// "no library found" message. See issue #45.
    enum Availability: Equatable {
        /// The DB is present and readable.
        case available
        /// No DB on disk — Voice Memos iCloud sync is off, or there are no
        /// recordings yet.
        case databaseMissing
        /// The DB path is blocked by the OS (missing Full Disk Access /
        /// Files-and-Folders grant). `reason` is the underlying errno text.
        case accessDenied(reason: String)
    }

    /// Classify whether — and why — the Voice Memos DB can be read. Probes
    /// real read permission with `access(2)` (not just presence) so a TCC
    /// denial is reported distinctly from a genuinely-absent library.
    var availability: Availability {
        if access(databaseURL.path, R_OK) == 0 {
            return .available
        }
        let err = errno
        switch err {
        case ENOENT, ENOTDIR:
            // A path component is genuinely absent — no synced library.
            return .databaseMissing
        default:
            // EPERM / EACCES (TCC denial) and any other unexpected failure:
            // the read didn't succeed and the file isn't simply missing, so
            // treat it as "blocked" and carry the reason for the log.
            return .accessDenied(reason: String(cString: strerror(err)))
        }
    }

    /// True when the Voice Memos DB is present and readable. Drives whether
    /// the Settings tab offers the feature or shows a hint.
    var isAvailable: Bool {
        availability == .available
    }

    // MARK: - Public API

    /// A folder in the Voice Memos library. `uuid` is the stable
    /// `ZFOLDER.ZUUID` (survives renames) — use it as the persisted key.
    /// `name` is for display only.
    struct Folder: Identifiable, Hashable {
        let uuid: String
        let name: String
        let count: Int
        var id: String { uuid }
    }

    /// One recording row, normalised. `folderUUID == nil` means the memo is
    /// unfiled (`ZFOLDER IS NULL`).
    struct Memo: Identifiable, Hashable {
        let uniqueID: String
        let fileURL: URL
        let folderUUID: String?
        let title: String
        let duration: Double
        let date: Date
        var id: String { uniqueID }

        /// `.composition` directories are multi-take/edited recordings, not
        /// flat audio files — out of scope for transcription.
        var isComposition: Bool {
            fileURL.pathExtension.lowercased() == "composition"
        }

        /// `.qta` is the newer (2025+) Voice Memos container that whisper /
        /// AVAudioFile can't open directly — flagged so the importer can
        /// skip it until a conversion step exists.
        var isUnsupportedFormat: Bool {
            fileURL.pathExtension.lowercased() == "qta"
        }
    }

    enum LibraryError: LocalizedError, Equatable {
        case databaseMissing
        case accessDenied(String)
        case openFailed(String)
        case schemaUnsupported

        var errorDescription: String? {
            switch self {
            case .databaseMissing:
                return "No Voice Memos library was found on this Mac."
            case .accessDenied:
                return "Mila can't read your Voice Memos library. Grant Mila Full Disk Access in "
                    + "System Settings → Privacy & Security → Full Disk Access, then reopen this tab."
            case .openFailed(let msg):
                return "Could not open the Voice Memos database: \(msg)"
            case .schemaUnsupported:
                return "The Voice Memos database has an unexpected layout this version of Mila can't read."
            }
        }
    }

    /// All real folders (unfiled recordings are not a folder — see
    /// `unfiledCount()`), each with its recording count.
    func folders() throws -> [Folder] {
        let db = try open()
        defer { sqlite3_close(db) }

        let folderCols = try columns(of: "ZFOLDER", db: db)
        guard folderCols.contains("ZUUID"), folderCols.contains("Z_PK") else {
            throw LibraryError.schemaUnsupported
        }
        let nameCol = Self.firstPresent(["ZENCRYPTEDNAME", "ZNAME", "ZCUSTOMLABEL"], in: folderCols)

        // Tally recordings per folder PK so we can show counts even for
        // schemas without ZNUMBEROFCONTAINEDRECORDINGS.
        let counts = try recordingCountsByFolderPK(db: db)

        let nameSelect = nameCol ?? "NULL"
        let sql = "SELECT Z_PK, ZUUID, \(nameSelect) FROM ZFOLDER WHERE ZUUID IS NOT NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LibraryError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var result: [Folder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            guard let uuid = Self.text(stmt, 1) else { continue }
            let name = Self.text(stmt, 2) ?? "Folder"
            result.append(Folder(uuid: uuid, name: name, count: counts[pk] ?? 0))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Number of unfiled recordings (`ZFOLDER IS NULL`). Often the majority
    /// of a library, so the UI surfaces it as an explicit "Unfiled" option.
    func unfiledCount() throws -> Int {
        let db = try open()
        defer { sqlite3_close(db) }
        let recCols = try columns(of: "ZCLOUDRECORDING", db: db)
        guard recCols.contains("ZFOLDER") else { return 0 }
        let evictionFilter = Self.firstPresent(["ZEVICTIONDATE"], in: recCols)
            .map { " AND \($0) IS NULL" } ?? ""
        let sql = "SELECT COUNT(*) FROM ZCLOUDRECORDING WHERE ZFOLDER IS NULL\(evictionFilter);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Recordings belonging to any of `folderUUIDs`, optionally including
    /// the unfiled bucket. Pass an empty set + `includeUnfiled: true` to get
    /// only unfiled memos. Evicted (Recently-Deleted-in-Voice-Memos)
    /// recordings are excluded.
    func recordings(folderUUIDs: Set<String>, includeUnfiled: Bool) throws -> [Memo] {
        let all = try fetchAllRecordings()
        return all.filter { memo in
            if let folder = memo.folderUUID {
                return folderUUIDs.contains(folder)
            } else {
                return includeUnfiled
            }
        }
    }

    // MARK: - Core fetch

    /// Every (non-evicted) recording in the library, normalised. The single
    /// scan that `recordings(...)` filters and that folder counts derive from.
    func fetchAllRecordings() throws -> [Memo] {
        let db = try open()
        defer { sqlite3_close(db) }

        let recCols = try columns(of: "ZCLOUDRECORDING", db: db)
        guard let pathCol = Self.firstPresent(["ZPATH", "ZURL"], in: recCols),
              let uniqueCol = Self.firstPresent(["ZUNIQUEID"], in: recCols) else {
            throw LibraryError.schemaUnsupported
        }
        let durationCol = Self.firstPresent(["ZDURATION"], in: recCols)
        let dateCol = Self.firstPresent(["ZDATE"], in: recCols)
        let titleCol = Self.firstPresent(["ZENCRYPTEDTITLE", "ZCUSTOMLABEL", "ZTITLE"], in: recCols)
        let folderCol = recCols.contains("ZFOLDER") ? "ZFOLDER" : nil
        let evictionCol = Self.firstPresent(["ZEVICTIONDATE"], in: recCols)

        let folderJoin = folderCol != nil
            ? "LEFT JOIN ZFOLDER f ON r.\(folderCol!) = f.Z_PK"
            : ""
        let folderSelect = folderCol != nil ? "f.ZUUID" : "NULL"
        let whereClause = evictionCol.map { "WHERE r.\($0) IS NULL" } ?? ""

        let sql = """
        SELECT r.\(uniqueCol), r.\(pathCol), \
        \(durationCol.map { "r.\($0)" } ?? "0"), \
        \(dateCol.map { "r.\($0)" } ?? "0"), \
        \(titleCol.map { "r.\($0)" } ?? "NULL"), \
        \(folderSelect) \
        FROM ZCLOUDRECORDING r \(folderJoin) \(whereClause);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LibraryError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var result: [Memo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uniqueID = Self.text(stmt, 0),
                  let path = Self.text(stmt, 1) else { continue }
            let duration = sqlite3_column_double(stmt, 2)
            let coreDataDate = sqlite3_column_double(stmt, 3)
            let title = Self.text(stmt, 4)
            let folderUUID = Self.text(stmt, 5)

            let fileURL = Self.resolve(path: path, relativeTo: recordingsDirectory)
            // ZDATE is a Core Data timestamp (seconds since 2001-01-01). Fall
            // back to the filename's leading timestamp, then the file's own
            // creation date, so a row with a zero/garbage ZDATE still sorts
            // sensibly instead of landing in 2001.
            let date = coreDataDate > 0
                ? Date(timeIntervalSinceReferenceDate: coreDataDate)
                : (Self.dateFromFilename(fileURL.lastPathComponent)
                   ?? Self.fileCreationDate(fileURL)
                   ?? Date(timeIntervalSinceReferenceDate: coreDataDate))

            let displayTitle = (title?.isEmpty == false)
                ? title!
                : fileURL.deletingPathExtension().lastPathComponent

            result.append(Memo(
                uniqueID: uniqueID,
                fileURL: fileURL,
                folderUUID: folderUUID,
                title: displayTitle,
                duration: duration,
                date: date
            ))
        }
        return result
    }

    // MARK: - SQLite helpers

    private func open() throws -> OpaquePointer {
        // Distinguish "no library" from "access denied" before touching
        // SQLite, so callers (and the log) get the right diagnostic instead
        // of a generic open failure. See issue #45.
        switch availability {
        case .available:
            break
        case .databaseMissing:
            throw LibraryError.databaseMissing
        case .accessDenied(let reason):
            throw LibraryError.accessDenied(reason)
        }
        // Read-only, opened by literal path (NOT a `file:` URI — a "?" or "#"
        // in the path would be parsed as URI query/fragment). The DB is
        // WAL-mode and actively written by voicememod; a read-only connection
        // reads through the WAL so freshly-synced rows are visible, and SQLite
        // guarantees readers never block or corrupt a concurrent writer. We
        // never issue a write.
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            throw LibraryError.openFailed(msg)
        }
        return db
    }

    /// Column names of `table`, upper-cased for case-insensitive matching.
    private func columns(of table: String, db: OpaquePointer) throws -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            throw LibraryError.schemaUnsupported
        }
        defer { sqlite3_finalize(stmt) }
        var cols: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = Self.text(stmt, 1) {
                cols.insert(name.uppercased())
            }
        }
        if cols.isEmpty { throw LibraryError.schemaUnsupported }
        return cols
    }

    /// Map of folder `Z_PK` → recording count (non-evicted), for `folders()`.
    private func recordingCountsByFolderPK(db: OpaquePointer) throws -> [Int64: Int] {
        let recCols = try columns(of: "ZCLOUDRECORDING", db: db)
        guard recCols.contains("ZFOLDER") else { return [:] }
        let evictionFilter = Self.firstPresent(["ZEVICTIONDATE"], in: recCols)
            .map { " WHERE \($0) IS NULL" } ?? ""
        let sql = "SELECT ZFOLDER, COUNT(*) FROM ZCLOUDRECORDING\(evictionFilter) GROUP BY ZFOLDER;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var counts: [Int64: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { continue }
            counts[sqlite3_column_int64(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1))
        }
        return counts
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let stmt, sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private static func firstPresent(_ candidates: [String], in columns: Set<String>) -> String? {
        candidates.first { columns.contains($0.uppercased()) }
    }

    /// Resolve a `ZPATH` value to an on-disk URL. ZPATH is normally a bare
    /// filename relative to the Recordings dir, but tolerate an absolute path
    /// just in case.
    private static func resolve(path: String, relativeTo base: URL) -> URL {
        // `ZURL`-style columns may carry a full "file:///…" URL string.
        if let url = URL(string: path), url.isFileURL {
            return url
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return base.appendingPathComponent(path)
    }

    /// Voice Memos names files `YYYYMMDD HHMMSS-XXXX.ext`; parse that leading
    /// stamp as a creation-date fallback.
    private static func dateFromFilename(_ name: String) -> Date? {
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "-", maxSplits: 1)
        guard let stamp = parts.first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd HHmmss"
        return formatter.date(from: String(stamp))
    }

    private static func fileCreationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
