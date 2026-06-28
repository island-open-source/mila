import XCTest
@testable import Mila

@MainActor
final class RecordingStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    func test_store_persists_recordings_across_instances() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        XCTAssertTrue(first.recordings.isEmpty)

        let recording = Recording(
            title: "Fixture",
            duration: 3.14,
            source: .microphone,
            audioFileName: "fixture.wav"
        )
        first.add(recording)
        XCTAssertEqual(first.recordings.count, 1)

        let second = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(second.recordings.count, 1)
        XCTAssertEqual(second.recordings.first?.id, recording.id)

        second.permanentlyDelete(recording)

        let third = RecordingStore(rootDirectory: tempRoot)
        XCTAssertTrue(third.recordings.isEmpty)
    }

    func test_soft_delete_moves_to_recently_deleted_and_restore_returns_it() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "X", source: .microphone, audioFileName: "x.wav")
        store.add(rec)

        XCTAssertTrue(store.recordings(in: .transcriptions).contains { $0.id == rec.id })
        XCTAssertFalse(store.recordings(in: .recentlyDeleted).contains { $0.id == rec.id })

        store.softDelete(rec)
        XCTAssertFalse(store.recordings(in: .transcriptions).contains { $0.id == rec.id })
        XCTAssertTrue(store.recordings(in: .recentlyDeleted).contains { $0.id == rec.id })

        if let trashed = store.recordings.first(where: { $0.id == rec.id }) {
            store.restore(trashed)
        }
        XCTAssertTrue(store.recordings(in: .transcriptions).contains { $0.id == rec.id })
        XCTAssertFalse(store.recordings(in: .recentlyDeleted).contains { $0.id == rec.id })
    }

    func test_recordings_in_category_classifies_correctly() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let mic = Recording(title: "Voice Memo · Today", source: .microphone, audioFileName: "a.wav")
        let dictation = Recording(title: "Dictation · Today", source: .microphone, audioFileName: "b.wav")
        let meeting = Recording(title: "Standup", source: .meeting, audioFileName: "c.wav")
        store.add(mic); store.add(dictation); store.add(meeting)

        XCTAssertEqual(store.recordings(in: .transcriptions).count, 3)
        XCTAssertEqual(store.recordings(in: .meetings).map(\.id), [meeting.id])
        XCTAssertEqual(store.recordings(in: .dictations).map(\.id), [dictation.id])
        XCTAssertEqual(store.recordings(in: .recentlyDeleted).count, 0)
    }

    func test_fresh_audio_url_is_unique_under_recordings_directory() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let a = store.freshAudioURL(suggestedName: "Hello")
        let b = store.freshAudioURL(suggestedName: "Hello")

        XCTAssertEqual(a.pathExtension, "wav")
        XCTAssertTrue(a.path.contains("Recordings"))
        XCTAssertTrue(a.lastPathComponent.hasPrefix("Hello "))
        XCTAssertNotEqual(a.lastPathComponent, b.lastPathComponent)
    }

    func test_creating_store_creates_models_and_recordings_dirs() {
        _ = RecordingStore(rootDirectory: tempRoot)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("Recordings").path,
            isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("Models").path,
            isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - Rename

    func test_rename_updates_title_and_persists_across_instances() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "Original", source: .microphone, audioFileName: "x.wav")
        store.add(rec)

        store.rename(rec, to: "Renamed")
        XCTAssertEqual(store.recordings.first?.title, "Renamed")

        let reloaded = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(reloaded.recordings.first?.title, "Renamed")
    }

    func test_rename_trims_whitespace_and_ignores_empty_input() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "Original", source: .microphone, audioFileName: "x.wav")
        store.add(rec)

        store.rename(rec, to: "  Trimmed  ")
        XCTAssertEqual(store.recordings.first?.title, "Trimmed")

        // Blank-only input must be a no-op so we never leave an empty row.
        store.rename(rec, to: "   ")
        XCTAssertEqual(store.recordings.first?.title, "Trimmed")
    }

    // MARK: - Folder CRUD

    func test_create_folder_adds_and_sorts_alphabetically() {
        let store = RecordingStore(rootDirectory: tempRoot)
        store.createFolder("Zebra")
        store.createFolder("apple")
        store.createFolder("Mango")
        XCTAssertEqual(store.folders, ["apple", "Mango", "Zebra"])
    }

    func test_create_folder_dedupes_case_insensitive_and_rejects_blank() {
        let store = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(store.createFolder("Work"), "Work")
        XCTAssertEqual(store.createFolder("work"), "Work")  // dedupe — returns canonical
        XCTAssertEqual(store.folders, ["Work"])
        XCTAssertNil(store.createFolder("   "))
        XCTAssertEqual(store.folders, ["Work"])
    }

    func test_folders_persist_across_store_instances() {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.createFolder("Work")
        first.createFolder("Personal")

        let second = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(second.folders, ["Personal", "Work"])
    }

    func test_assign_recording_to_folder_filters_correctly() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec1 = Recording(title: "A", source: .microphone, audioFileName: "a.wav")
        let rec2 = Recording(title: "B", source: .microphone, audioFileName: "b.wav")
        store.add(rec1); store.add(rec2)
        store.createFolder("Work")

        store.assign(rec1, toFolder: "Work")
        XCTAssertEqual(store.recordings(inFolder: "Work").map(\.id), [rec1.id])
        XCTAssertTrue(store.recordings(inFolder: "Personal").isEmpty)
    }

    /// Regression: `assign` used to compare folder names case-sensitively
    /// when its auto-create branch checked for an existing entry, which
    /// let "work" + "Work" coexist depending on which path created each.
    func test_assign_with_case_variant_reuses_existing_folder() {
        let store = RecordingStore(rootDirectory: tempRoot)
        store.createFolder("Work")
        let rec = Recording(title: "A", source: .microphone, audioFileName: "a.wav")
        store.add(rec)

        store.assign(rec, toFolder: "work")
        XCTAssertEqual(store.folders, ["Work"])
        XCTAssertEqual(store.recordings.first?.folder, "Work")
    }

    func test_assign_to_new_folder_auto_creates_it() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "A", source: .microphone, audioFileName: "a.wav")
        store.add(rec)
        XCTAssertTrue(store.folders.isEmpty)

        store.assign(rec, toFolder: "Drafts")
        XCTAssertEqual(store.folders, ["Drafts"])
        XCTAssertEqual(store.recordings(inFolder: "Drafts").map(\.id), [rec.id])
    }

    func test_assign_nil_unfiles_recording() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "A", source: .microphone, audioFileName: "a.wav")
        store.add(rec)
        store.assign(rec, toFolder: "Work")
        XCTAssertEqual(store.recordings.first?.folder, "Work")

        store.assign(rec, toFolder: nil)
        XCTAssertNil(store.recordings.first?.folder)
        XCTAssertTrue(store.recordings(inFolder: "Work").isEmpty)
        // The empty folder itself sticks around for the sidebar.
        XCTAssertEqual(store.folders, ["Work"])
    }

    func test_rename_folder_retags_recordings() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "A", source: .microphone, audioFileName: "a.wav")
        store.add(rec)
        store.assign(rec, toFolder: "Work")

        XCTAssertEqual(store.renameFolder("Work", to: "Office"), "Office")
        XCTAssertEqual(store.folders, ["Office"])
        XCTAssertEqual(store.recordings.first?.folder, "Office")
    }

    func test_rename_folder_rejects_collision() {
        let store = RecordingStore(rootDirectory: tempRoot)
        store.createFolder("Work")
        store.createFolder("Personal")

        XCTAssertNil(store.renameFolder("Work", to: "Personal"))
        XCTAssertEqual(store.folders, ["Personal", "Work"])
    }

    /// Regression: a case-only rename ("work" -> "Work") used to false-positive
    /// the case-insensitive collision check against the folder being renamed.
    func test_rename_folder_allows_case_only_change() {
        let store = RecordingStore(rootDirectory: tempRoot)
        store.createFolder("work")
        let rec = Recording(title: "A", source: .microphone, audioFileName: "a.wav")
        store.add(rec)
        store.assign(rec, toFolder: "work")

        XCTAssertEqual(store.renameFolder("work", to: "Work"), "Work")
        XCTAssertEqual(store.folders, ["Work"])
        XCTAssertEqual(store.recordings.first?.folder, "Work")
    }

    func test_delete_folder_unfiles_recordings_and_persists() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "A", source: .microphone, audioFileName: "a.wav")
        store.add(rec)
        store.assign(rec, toFolder: "Work")

        store.deleteFolder("Work")
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertNil(store.recordings.first?.folder)

        let reloaded = RecordingStore(rootDirectory: tempRoot)
        XCTAssertTrue(reloaded.folders.isEmpty)
        XCTAssertNil(reloaded.recordings.first?.folder)
    }

    func test_unfiled_recordings_returns_only_unfiled_non_trashed() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let unfiled = Recording(title: "A", source: .microphone, audioFileName: "a.wav")
        let filed = Recording(title: "B", source: .microphone, audioFileName: "b.wav")
        let trashed = Recording(title: "C", source: .microphone, audioFileName: "c.wav")
        store.add(unfiled); store.add(filed); store.add(trashed)
        store.assign(filed, toFolder: "Work")
        store.softDelete(trashed)

        let result = store.unfiledRecordings()
        XCTAssertEqual(result.map(\.id), [unfiled.id])
    }

    // MARK: - Summary sidecar

    func test_summary_sidecar_written_when_recording_has_summary() throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        var rec = Recording(title: "S", source: .microphone, audioFileName: "s.wav")
        rec.summary = "Decisions: ship it."
        store.add(rec)

        let url = store.summaryURL(for: rec)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Expected sidecar at \(url.path)")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "Decisions: ship it.")
    }

    func test_summary_sidecar_absent_when_summary_is_nil() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "S", source: .microphone, audioFileName: "s.wav")
        store.add(rec)
        let url = store.summaryURL(for: rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Nil summary should not leave a stub file")
    }

    func test_summary_sidecar_deleted_when_summary_cleared_to_empty() throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        var rec = Recording(title: "S", source: .microphone, audioFileName: "s.wav")
        rec.summary = "Original summary"
        store.add(rec)
        let url = store.summaryURL(for: rec)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        rec.summary = ""
        store.update(rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Clearing summary to empty must remove the sidecar")

        rec.summary = nil
        store.update(rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Setting summary to nil must remove the sidecar")
    }

    func test_summary_sidecar_updated_on_update() throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        var rec = Recording(title: "S", source: .microphone, audioFileName: "s.wav")
        rec.summary = "v1"
        store.add(rec)

        rec.summary = "v2 with more detail"
        store.update(rec)
        let onDisk = try String(contentsOf: store.summaryURL(for: rec), encoding: .utf8)
        XCTAssertEqual(onDisk, "v2 with more detail")
    }

    func test_permanently_delete_removes_summary_sidecar() throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        var rec = Recording(title: "S", source: .microphone, audioFileName: "s.wav")
        rec.summary = "Going away"
        store.add(rec)
        let url = store.summaryURL(for: rec)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        store.permanentlyDelete(rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "permanentlyDelete must remove the summary sidecar too")
    }

    func test_permanently_delete_removes_subtitle_sidecar() throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "S", source: .microphone, audioFileName: "s.wav")
        store.add(rec)
        // The .srt sidecar is written post-transcription by TranscriptExporter,
        // not by add() — simulate it landing next to the audio.
        let srt = store.subtitleURL(for: rec)
        try "1\n00:00:00,000 --> 00:00:01,000\nhi\n".write(to: srt, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srt.path))

        store.permanentlyDelete(rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: srt.path),
                       "permanentlyDelete must remove the .srt subtitle sidecar too")
    }

    func test_subtitle_filename_derived_from_audio_filename() {
        let rec = Recording(title: "X",
                            source: .microphone,
                            audioFileName: "Voice Memo 2024-01-01.m4a")
        XCTAssertEqual(rec.subtitleFileName, "Voice Memo 2024-01-01.srt")
    }

    func test_summary_filename_derived_from_audio_filename() {
        let rec = Recording(title: "X",
                            source: .microphone,
                            audioFileName: "Voice Memo 2024-01-01.wav")
        XCTAssertEqual(rec.summaryFileName, "Voice Memo 2024-01-01.summary.txt")
    }

    func test_summary_sidecar_trims_whitespace() throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        var rec = Recording(title: "S", source: .microphone, audioFileName: "s.wav")
        // Whitespace-only summaries are effectively empty — the sidecar
        // should NOT be written for those.
        rec.summary = "   \n\n  "
        store.add(rec)
        let url = store.summaryURL(for: rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Whitespace-only summary must be treated as empty")
    }

    func test_load_seeds_folders_from_recordings_when_folders_file_missing() throws {
        // Simulates a recordings.json that already references a folder name
        // (e.g. after restoring from backup, or hand-editing the JSON).
        let store = RecordingStore(rootDirectory: tempRoot)
        var rec = Recording(title: "A", source: .microphone, audioFileName: "a.wav")
        rec.folder = "Imported"
        store.add(rec)

        // Wipe folders.json to mimic a partial import.
        let foldersURL = tempRoot.appendingPathComponent("folders.json")
        try? FileManager.default.removeItem(at: foldersURL)

        let reloaded = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(reloaded.folders, ["Imported"])
    }
}
