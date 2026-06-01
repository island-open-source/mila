import XCTest
@testable import TranscriptionCore

final class CoreMLStatusParseTests: XCTestCase {

    func test_loaded_lines_extract_path() {
        let lines = [
            "whisper_init_state: loading Core ML model from '/tmp/ggml-tiny-encoder.mlmodelc'\n",
            "whisper_init_state: first run on a device may take a while ...\n",
            "whisper_init_state: Core ML model loaded\n",
        ]
        let status = WhisperEngine.parseCoreMLStatus(from: lines)
        XCTAssertEqual(status, .loaded(path: "/tmp/ggml-tiny-encoder.mlmodelc"))
    }

    func test_failed_but_file_missing_reports_unavailable() {
        // The common case: no `.mlmodelc` sibling next to the `.bin`. whisper.cpp
        // still emits the "loading ... failed to load" pair; we shouldn't surface
        // that as a real failure, just `.unavailable`.
        let absent = "/tmp/definitely-not-a-real-mlmodelc-\(UUID().uuidString).mlmodelc"
        let lines = [
            "whisper_init_state: loading Core ML model from '\(absent)'\n",
            "whisper_init_state: failed to load Core ML model from '\(absent)'\n",
        ]
        XCTAssertEqual(WhisperEngine.parseCoreMLStatus(from: lines), .unavailable)
    }

    func test_failed_with_existing_file_reports_failed() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreml-parse-\(UUID().uuidString).mlmodelc")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lines = [
            "whisper_init_state: loading Core ML model from '\(tmpDir.path)'\n",
            "whisper_init_state: failed to load Core ML model from '\(tmpDir.path)'\n",
        ]
        guard case .failed(let reason) = WhisperEngine.parseCoreMLStatus(from: lines) else {
            return XCTFail("Expected .failed when sibling exists but load failed")
        }
        XCTAssertTrue(reason.contains(tmpDir.path))
    }

    func test_no_core_ml_lines_reports_unavailable() {
        let lines = [
            "whisper_init_from_file_with_params_no_state: loading model from 'whatever.bin'\n",
            "whisper_init_with_params_no_state: use gpu    = 1\n",
        ]
        XCTAssertEqual(WhisperEngine.parseCoreMLStatus(from: lines), .unavailable)
    }
}
