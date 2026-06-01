import XCTest
import TranscriptionCore

/// Integration test that verifies whisper.cpp's CoreML / ANE path is
/// actually engaged when a sibling `<bin-without-ext>-encoder.mlmodelc`
/// is present next to the `.bin` weights.
///
/// Gated on `MILA_COREML_E2E=1` so local `make test` runs don't load a
/// real whisper context. CI sets the flag, downloads `ggml-tiny.bin` +
/// `ggml-tiny-encoder.mlmodelc` into a known cache dir, and points
/// `MILA_COREML_MODEL` at the `.bin` — see `.github/workflows/ci.yml`.
///
/// This is the "verify it used it" guard for the ANE work on PR #32:
/// the assertion is grounded in whisper.cpp's own init log lines via
/// `whisper_log_set`, not in file-presence guesses.
final class WhisperEngineCoreMLTests: XCTestCase {
    func test_coreml_engages_when_mlmodelc_sibling_present() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_COREML_E2E"] == "1",
            "Set MILA_COREML_E2E=1 to run; needs whisper bin + sibling .mlmodelc on disk."
        )
        guard let modelPath = ProcessInfo.processInfo.environment["MILA_COREML_MODEL"] else {
            throw XCTSkip("MILA_COREML_MODEL not set — point it at a ggml-*.bin with a sibling -encoder.mlmodelc")
        }
        let modelURL = URL(fileURLWithPath: modelPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path),
                      "Bin missing: \(modelURL.path)")
        let mlPath = modelURL.deletingPathExtension().path + "-encoder.mlmodelc"
        XCTAssertTrue(FileManager.default.fileExists(atPath: mlPath),
                      "Sibling .mlmodelc missing: \(mlPath)")

        let engine = WhisperEngine()
        try await engine.loadIfNeeded(modelURL: modelURL, displayName: "coreml-ci-test")
        let status = await engine.coreMLStatus

        // The assertion: whisper.cpp must have logged "Core ML model loaded"
        // during init AND the path it reported must match the sibling we
        // verified on disk above. This proves the encoder is on CoreML
        // (which on Apple Silicon dispatches the FP16 encoder to ANE).
        switch status {
        case .loaded(let reportedPath):
            XCTAssertEqual(reportedPath, mlPath,
                           "Loaded mlmodelc path should match the sibling we verified on disk")
        case .failed(let reason):
            XCTFail("CoreML init failed: \(reason)")
        case .unavailable:
            XCTFail("Expected CoreML to engage but status is .unavailable — whisper.cpp's log callback never saw 'Core ML model loaded'. Check that the sibling .mlmodelc was generated for the same model architecture.")
        }
    }
}
