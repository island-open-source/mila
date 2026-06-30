import XCTest
import SQLite3
@testable import Mila

/// Exercises the read-only `CloudRecordings.db` reader against a synthetic
/// database that mimics the Core Data layout the iPhone Voice Memos app uses
/// (we can't ship the real, private DB into CI). Validates the folder join,
/// the unfiled bucket, eviction filtering, date conversion and the
/// format/composition flags the importer keys on.
final class VoiceMemosLibraryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = TestSupport.makeTempRoot(label: "VoiceMemosLibraryTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    // MARK: - Fixture

    /// Build a minimal CloudRecordings.db. Z_PK 1=Work, 2=Ideas.
    private func makeFixtureLibrary() throws -> VoiceMemosLibrary {
        let dbURL = tempRoot.appendingPathComponent("CloudRecordings.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZENCRYPTEDNAME TEXT);
        CREATE TABLE ZCLOUDRECORDING (
            Z_PK INTEGER PRIMARY KEY, ZFOLDER INTEGER, ZUNIQUEID TEXT, ZPATH TEXT,
            ZDURATION FLOAT, ZDATE FLOAT, ZENCRYPTEDTITLE TEXT, ZEVICTIONDATE FLOAT
        );
        INSERT INTO ZFOLDER VALUES (1, 'UUID-WORK', 'Work'), (2, 'UUID-IDEAS', 'Ideas');
        INSERT INTO ZCLOUDRECORDING VALUES
            (1, 1,    'rec-1', 'file1.m4a',        12.0, 700000000.0, 'Memo One',     NULL),
            (2, 1,    'rec-2', 'file2.m4a',         2.0, 700000100.0, 'Short Clip',   NULL),
            (3, 2,    'rec-3', 'file3.m4a',        30.0, 700000200.0, 'An Idea',      NULL),
            (4, NULL, 'rec-4', 'file4.m4a',        20.0, 700000300.0, 'Unfiled One',  NULL),
            (5, 1,    'rec-5', 'file5.m4a',        40.0, 700000400.0, 'Deleted',  123456.0),
            (6, 1,    'rec-6', 'file6.qta',        15.0, 700000500.0, 'New Format',   NULL),
            (7, NULL, 'rec-7', 'file7.composition',15.0, 700000600.0, 'Multi Take',   NULL);
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            XCTFail("Failed to seed fixture DB: \(message)")
        }
        return VoiceMemosLibrary(recordingsDirectory: tempRoot)
    }

    // MARK: - Tests

    /// A genuinely-absent DB classifies as `.databaseMissing` (not denied),
    /// and reads throw the matching `.databaseMissing` error.
    func test_isAvailable_falseWhenDatabaseMissing() {
        let lib = VoiceMemosLibrary(recordingsDirectory: tempRoot)
        XCTAssertFalse(lib.isAvailable)
        XCTAssertEqual(lib.availability, .databaseMissing)
        XCTAssertThrowsError(try lib.fetchAllRecordings()) { error in
            XCTAssertEqual(error as? VoiceMemosLibrary.LibraryError, .databaseMissing)
        }
    }

    /// A present, readable fixture DB classifies as `.available`.
    func test_availability_availableForReadableDatabase() throws {
        let lib = try makeFixtureLibrary()
        XCTAssertEqual(lib.availability, .available)
        XCTAssertTrue(lib.isAvailable)
    }

    /// A present-but-unreadable DB (the TCC / Full Disk Access denial case,
    /// simulated here by stripping read permission) must classify as
    /// `accessDenied` — distinct from "missing" — and surface a thrown
    /// `.accessDenied` rather than a generic open failure. See issue #45.
    func test_availability_accessDeniedWhenUnreadable() throws {
        // access(2) ignores permission bits for the superuser, so this can't
        // be exercised as root; skip rather than report a false failure.
        try XCTSkipIf(getuid() == 0, "access(2) bypasses permission checks as root")

        let lib = try makeFixtureLibrary()
        let dbURL = tempRoot.appendingPathComponent("CloudRecordings.db")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbURL.path)
        defer {
            // Restore so tearDown's cleanup isn't affected on any platform.
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)
        }

        XCTAssertFalse(lib.isAvailable)
        guard case .accessDenied = lib.availability else {
            return XCTFail("expected .accessDenied, got \(lib.availability)")
        }
        XCTAssertThrowsError(try lib.fetchAllRecordings()) { error in
            guard case .accessDenied = error as? VoiceMemosLibrary.LibraryError else {
                return XCTFail("expected LibraryError.accessDenied, got \(error)")
            }
        }
    }

    func test_folders_returnsSortedFoldersWithNonEvictedCounts() throws {
        let lib = try makeFixtureLibrary()
        let folders = try lib.folders()
        XCTAssertEqual(folders.map(\.name), ["Ideas", "Work"])  // sorted by name

        let work = try XCTUnwrap(folders.first { $0.uuid == "UUID-WORK" })
        // ZFOLDER=1, non-evicted: rec-1, rec-2, rec-6 (rec-5 is evicted).
        XCTAssertEqual(work.count, 3)
        let ideas = try XCTUnwrap(folders.first { $0.uuid == "UUID-IDEAS" })
        XCTAssertEqual(ideas.count, 1)
    }

    func test_unfiledCount_excludesEvicted() throws {
        let lib = try makeFixtureLibrary()
        // ZFOLDER IS NULL, non-evicted: rec-4, rec-7.
        XCTAssertEqual(try lib.unfiledCount(), 2)
    }

    func test_recordings_filtersByFolderAndExcludesEvicted() throws {
        let lib = try makeFixtureLibrary()
        let work = try lib.recordings(folderUUIDs: ["UUID-WORK"], includeUnfiled: false)
        XCTAssertEqual(Set(work.map(\.uniqueID)), ["rec-1", "rec-2", "rec-6"])
        XCTAssertTrue(work.allSatisfy { $0.folderUUID == "UUID-WORK" })
        XCTAssertFalse(work.contains { $0.uniqueID == "rec-5" })  // evicted
    }

    func test_recordings_includeUnfiledOnly() throws {
        let lib = try makeFixtureLibrary()
        let unfiled = try lib.recordings(folderUUIDs: [], includeUnfiled: true)
        XCTAssertEqual(Set(unfiled.map(\.uniqueID)), ["rec-4", "rec-7"])
        XCTAssertTrue(unfiled.allSatisfy { $0.folderUUID == nil })
    }

    func test_memo_metadataAndFlags() throws {
        let lib = try makeFixtureLibrary()
        let all = try lib.fetchAllRecordings()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.uniqueID, $0) })

        let rec1 = try XCTUnwrap(byID["rec-1"])
        XCTAssertEqual(rec1.title, "Memo One")
        XCTAssertEqual(rec1.duration, 12.0, accuracy: 0.001)
        XCTAssertEqual(rec1.date, Date(timeIntervalSinceReferenceDate: 700000000.0))
        XCTAssertEqual(rec1.fileURL, tempRoot.appendingPathComponent("file1.m4a"))
        XCTAssertFalse(rec1.isUnsupportedFormat)
        XCTAssertFalse(rec1.isComposition)

        XCTAssertTrue(try XCTUnwrap(byID["rec-6"]).isUnsupportedFormat)  // .qta
        XCTAssertTrue(try XCTUnwrap(byID["rec-7"]).isComposition)        // .composition
    }
}
