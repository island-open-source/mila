import Foundation
import Combine
import CryptoKit
import os.log

private let modelLogger = MilaLog(category: "models")

/// Catalog of supported ggml models. Add more here as needed.
struct WhisperModel: Identifiable, Hashable, Codable {
    var id: String { name }
    var name: String
    var displayName: String
    var url: URL
    var sizeBytes: Int64
    /// Lowercase hex SHA-256 of the file at `url`. Pinned so that a
    /// compromised HuggingFace repo (or any swap of the .bin between the URL
    /// being fetched and our parser opening it) is rejected before the bytes
    /// ever reach whisper.cpp's GGML loader.
    var sha256: String
    var languageHint: String

    /// URL of an `<name>-encoder.mlmodelc.zip` (CoreML encoder build of the
    /// same model). When present, ModelManager downloads + extracts it
    /// alongside the `.bin` so whisper.cpp's auto-detect routes the
    /// encoder to CoreML / Apple Neural Engine. Optional: a model without
    /// a CoreML build still works fine on Metal/CPU.
    var coreMLURL: URL?
    var coreMLSizeBytes: Int64
    var coreMLSHA256: String?

    /// Hebrew default. The full ivrit.ai `large-v3` finetune (~3 GB, ~2x
    /// slower than the turbo variant). Empirically noticeably more accurate
    /// than the turbo finetune on Hebrew speech, which is why we ship it as
    /// the default despite the size and latency cost.
    static let ivritLarge = WhisperModel(
        name: "ivrit-ai-whisper-large-v3",
        displayName: "ivrit.ai · large-v3 (Hebrew)",
        url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-ggml/resolve/main/ggml-model.bin")!,
        sizeBytes: 3_095_033_483,
        sha256: "09e66ec67b2e00c6933afab6684cbf78fe023e8ad153c1848f62000e4335a07f",
        languageHint: "he",
        // CoreML encoder mlmodelc generated via whisper.cpp's
        // convert-h5-to-coreml.py against the ivrit-ai HuggingFace
        // checkpoint, hosted by us at uriharduf/whisper-large-v3-ivrit-coreml
        // (Apache-2.0, same license as the upstream base model).
        coreMLURL: URL(string: "https://huggingface.co/uriharduf/whisper-large-v3-ivrit-coreml/resolve/main/ivrit-ai-whisper-large-v3-encoder.mlmodelc.zip")!,
        coreMLSizeBytes: 1_174_466_438,
        coreMLSHA256: "a6cf2c2c88cfd011b981d0895d9a9b02db7c8475375d9b026f9cd4ab0d85ae78"
    )

    /// English (and any other multilingual) default. As of mid-2026 this is
    /// the open-weights state of the art for English at this size class —
    /// faster than full `large-v3` for essentially identical English WER, and
    /// it's the same checkpoint Whisper.cpp ships by default.
    static let openaiTurbo = WhisperModel(
        name: "openai-whisper-large-v3-turbo",
        displayName: "OpenAI · large-v3-turbo (English / multilingual)",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        sizeBytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        languageHint: "en",
        // CoreML encoder published by ggerganov/whisper.cpp directly.
        coreMLURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-encoder.mlmodelc.zip")!,
        coreMLSizeBytes: 1_173_393_014,
        coreMLSHA256: "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a"
    )

    static let all: [WhisperModel] = [.ivritLarge, .openaiTurbo]

    /// Pick the best model the catalog knows about for a given ISO language
    /// code. Hebrew goes to ivrit.ai's large-v3 finetune; everything else
    /// (including the dictation English path) goes to the OpenAI turbo.
    static func bestModel(for languageCode: String) -> WhisperModel {
        switch languageCode.lowercased() {
        case "he", "he-il", "iw":
            return .ivritLarge
        default:
            return .openaiTurbo
        }
    }
}

/// Downloads + tracks installed Whisper models on disk.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloads: [String: Double] = [:]
    @Published var selectedModelName: String

    private let modelsDirectory: URL
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var observers: [Int: WhisperModel] = [:]
    private var didShutDownSession = false

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
        let lastUsed = UserDefaults.standard.string(forKey: "selectedModelName")
        self.selectedModelName = lastUsed ?? WhisperModel.ivritLarge.name
        super.init()
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        refreshInstalled()
    }

    func selectedModel() -> WhisperModel? {
        WhisperModel.all.first { $0.name == selectedModelName }
    }

    func setSelected(_ model: WhisperModel) {
        selectedModelName = model.name
        UserDefaults.standard.set(model.name, forKey: "selectedModelName")
    }

    /// The model the app should use when transcribing audio in `languageCode`.
    /// Falls back to `selectedModel()` if the language-best model isn't
    /// installed yet (so dictation can still work in offline-but-different
    /// language mode while a download is in flight).
    func model(for languageCode: String) -> WhisperModel? {
        // "auto" = let whisper detect each utterance's language rather than
        // forcing one. Keep the user's *selected* model so a Hebrew user
        // doesn't trade ivrit.ai's Hebrew accuracy for the multilingual
        // generalist just to catch the occasional English sentence; both
        // shipped models are multilingual-capable, so detection still routes
        // English utterances to English text. Fall back to the turbo
        // (explicitly multilingual) if nothing usable is selected.
        if languageCode.lowercased() == "auto" {
            if let selected = selectedModel(), isInstalled(selected) { return selected }
            if isInstalled(.openaiTurbo) { return .openaiTurbo }
            return selectedModel() ?? .openaiTurbo
        }
        let best = WhisperModel.bestModel(for: languageCode)
        if isInstalled(best) { return best }
        return selectedModel().flatMap { isInstalled($0) ? $0 : nil } ?? best
    }

    /// Test-only override that makes every model's `url(for:)` return the
    /// same path (typically a small `ggml-tiny.bin` on disk). Lets CI
    /// run the real WhisperEngine on a fast model without rebuilding
    /// the production catalog. `isInstalled` returns true while the
    /// override is set so callers don't gate on the catalog filename
    /// existing.
    func setTestModelOverride(_ url: URL?) {
        testModelOverride = url
        modelLogger.log("setTestModelOverride: \(url?.path ?? "nil", privacy: .public)")
    }

    private var testModelOverride: URL?

    func url(for model: WhisperModel) -> URL {
        if let override = testModelOverride { return override }
        return modelsDirectory.appendingPathComponent("\(model.name).bin")
    }

    /// Disk path of the sibling `-encoder.mlmodelc` directory whisper.cpp
    /// looks for next to the `.bin`. Returns nil if the model has no
    /// CoreML build defined (Mila falls back to Metal/CPU encoder).
    func coreMLDirectory(for model: WhisperModel) -> URL? {
        guard model.coreMLURL != nil else { return nil }
        return modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc")
    }

    /// True iff the model's sibling `.mlmodelc` directory is on disk.
    /// Independent of whether the `.bin` is present. Used to gate
    /// "fresh install needs CoreML" auto-download.
    func isCoreMLInstalled(_ model: WhisperModel) -> Bool {
        guard let dir = coreMLDirectory(for: model) else { return false }
        return FileManager.default.fileExists(atPath: dir.path)
    }

    func isInstalled(_ model: WhisperModel) -> Bool {
        if testModelOverride != nil { return true }
        return installed.contains(model.name)
    }

    func refreshInstalled() {
        let fm = FileManager.default
        var found: Set<String> = []
        for model in WhisperModel.all where fm.fileExists(atPath: url(for: model).path) {
            found.insert(model.name)
        }
        installed = found
        modelLogger.log("refreshInstalled: dir=\(self.modelsDirectory.path, privacy: .public) found=\(found, privacy: .public)")
    }

    func delete(_ model: WhisperModel) throws {
        try FileManager.default.removeItem(at: url(for: model))
        refreshInstalled()
    }

    func download(_ model: WhisperModel) {
        guard downloads[model.name] == nil else { return }
        guard !didShutDownSession else { return }
        downloads[model.name] = 0
        let task = session.downloadTask(with: model.url)
        observers[task.taskIdentifier] = model
        task.resume()
    }

    /// Tracks the CoreML zip download keyed by URLSessionTask id, separately
    /// from the `.bin` `observers` map so a parallel CoreML fetch can't
    /// race with the .bin's progress callback. The Bool slot in
    /// `coreMLDownloads` reuses the same UI scheme as `downloads`.
    private var coreMLObservers: [Int: WhisperModel] = [:]
    @Published private(set) var coreMLDownloads: [String: Double] = [:]

    /// Download + extract the `<model>-encoder.mlmodelc.zip` from
    /// `model.coreMLURL` and place the resulting `.mlmodelc` directory
    /// next to the `.bin`. No-op if the model has no CoreML build or
    /// it's already installed. Failures are logged but never thrown —
    /// the app still works without CoreML (encoder runs on Metal).
    func downloadCoreML(_ model: WhisperModel) {
        guard let coreMLURL = model.coreMLURL else { return }
        guard !isCoreMLInstalled(model) else { return }
        guard coreMLDownloads[model.name] == nil else { return }
        guard !didShutDownSession else { return }
        coreMLDownloads[model.name] = 0
        let task = session.downloadTask(with: coreMLURL)
        coreMLObservers[task.taskIdentifier] = model
        task.resume()
    }

    /// Best-effort: kick off auto-downloads for any missing `-encoder.mlmodelc`
    /// for already-installed `.bin` weights. Called at startup + after
    /// every successful `.bin` install. The user pays disk + bandwidth
    /// once per model; subsequent launches see the sibling and skip.
    func ensureCoreMLInstalled() {
        for model in WhisperModel.all
        where isInstalled(model) && !isCoreMLInstalled(model) && model.coreMLURL != nil {
            modelLogger.notice("Auto-downloading CoreML encoder for \(model.name, privacy: .public)")
            downloadCoreML(model)
        }
    }

    /// Cancel any in-flight downloads and break the URLSession <-> delegate
    /// retain cycle. Called from the AppDelegate at shutdown so we don't
    /// crash later in delegate callbacks against a partially-deallocated
    /// `ModelManager`.
    func shutdown() {
        guard !didShutDownSession else { return }
        didShutDownSession = true
        observers.removeAll()
        downloads.removeAll()
        session.invalidateAndCancel()
    }

    enum VerifyError: Swift.Error, LocalizedError {
        case sha256Mismatch(expected: String, computed: String)

        var errorDescription: String? {
            switch self {
            case .sha256Mismatch(let expected, let computed):
                return "SHA-256 mismatch (expected \(expected), got \(computed))"
            }
        }
    }

    /// Streaming SHA-256 of the file at `fileURL`. Throws `VerifyError`
    /// on mismatch. Streamed in 1 MiB chunks so we don't have to load the
    /// whole multi-GB .bin into memory. `nonisolated` so we can dispatch
    /// the multi-second hash off the main actor.
    nonisolated static func verifySHA256(at fileURL: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let computed = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        if computed.lowercased() != expected.lowercased() {
            throw VerifyError.sha256Mismatch(expected: expected, computed: computed)
        }
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        Task { @MainActor in
            if let model = self.observers[id] {
                let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.sizeBytes
                let progress = Double(totalBytesWritten) / Double(total)
                self.downloads[model.name] = max(0, min(1, progress))
            } else if let model = self.coreMLObservers[id] {
                let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.coreMLSizeBytes
                let progress = Double(totalBytesWritten) / Double(total)
                self.coreMLDownloads[model.name] = max(0, min(1, progress))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        let moveErr: Error?
        do {
            try FileManager.default.moveItem(at: location, to: tempCopy)
            moveErr = nil
        } catch {
            moveErr = error
        }
        Task { @MainActor in
            // Demultiplex: is this the .bin or the CoreML zip?
            if let model = self.coreMLObservers.removeValue(forKey: id) {
                defer { self.coreMLDownloads.removeValue(forKey: model.name) }
                await self.finishCoreMLDownload(model: model, tempCopy: tempCopy, moveErr: moveErr)
                return
            }
            guard let model = self.observers.removeValue(forKey: id) else { return }
            // Keep `downloads[model.name]` set until we're truly done (verified
            // AND installed, or failed) — otherwise during the multi-second
            // off-main hash the duplicate-download guard in `download(_:)` and
            // the auto-download check in `ensureDefaultModelsInstalled` both
            // see no in-flight download and can kick off a redundant fetch of
            // the same 3 GB file.
            defer {
                self.downloads.removeValue(forKey: model.name)
                // Now that the .bin is on disk, auto-fetch the sibling
                // CoreML encoder (no-op if absent or already installed).
                self.downloadCoreML(model)
            }
            if let moveErr {
                modelLogger.error("Download \(model.name, privacy: .public): failed to capture URLSession temp file: \(moveErr.localizedDescription, privacy: .public)")
                return
            }
            // Hash off the main actor — for the 3 GB ivritLarge model this is
            // a multi-second blocking read, and we don't want to freeze the UI
            // (progress sheet, settings list) while it runs.
            let expected = model.sha256
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ModelManager.verifySHA256(at: tempCopy, expected: expected)
                }.value
                modelLogger.notice("Download \(model.name, privacy: .public): SHA-256 verified")
            } catch {
                try? FileManager.default.removeItem(at: tempCopy)
                modelLogger.error("Download \(model.name, privacy: .public): integrity check failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            let dest = self.url(for: model)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempCopy, to: dest)
                modelLogger.notice("Download \(model.name, privacy: .public): installed at \(dest.path, privacy: .public)")
            } catch {
                modelLogger.error("Download \(model.name, privacy: .public): final move failed: \(error.localizedDescription, privacy: .public)")
            }
            self.refreshInstalled()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        Task { @MainActor in
            if let model = self.observers.removeValue(forKey: id) {
                self.downloads.removeValue(forKey: model.name)
                modelLogger.error("Download \(model.name, privacy: .public): network/task failure: \(error.localizedDescription, privacy: .public)")
            } else if let model = self.coreMLObservers.removeValue(forKey: id) {
                self.coreMLDownloads.removeValue(forKey: model.name)
                modelLogger.error("CoreML download \(model.name, privacy: .public): network/task failure: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Finish a CoreML zip download: verify SHA-256, unzip into a temp dir,
    /// move the inner `.mlmodelc` directory to its sibling slot next to
    /// the `.bin`. Errors are logged but never thrown — Mila still works
    /// on Metal/CPU when CoreML isn't available.
    fileprivate func finishCoreMLDownload(model: WhisperModel, tempCopy: URL, moveErr: Error?) async {
        if let moveErr {
            modelLogger.error("CoreML download \(model.name, privacy: .public): URLSession temp move failed: \(moveErr.localizedDescription, privacy: .public)")
            return
        }
        guard let expected = model.coreMLSHA256 else {
            try? FileManager.default.removeItem(at: tempCopy)
            modelLogger.error("CoreML download \(model.name, privacy: .public): no expected SHA-256 in catalog — refusing to install unverified bytes")
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try ModelManager.verifySHA256(at: tempCopy, expected: expected)
            }.value
            modelLogger.notice("CoreML download \(model.name, privacy: .public): SHA-256 verified")
        } catch {
            try? FileManager.default.removeItem(at: tempCopy)
            modelLogger.error("CoreML download \(model.name, privacy: .public): integrity check failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let destDir = coreMLDirectory(for: model) else {
            try? FileManager.default.removeItem(at: tempCopy)
            return
        }

        // Unzip + place atomically. Existing dir gets blown away first so a
        // half-extracted state from a previous crash doesn't poison this
        // install.
        let extractRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlmodelc-extract-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        } catch {
            modelLogger.error("CoreML download \(model.name, privacy: .public): failed to create extract dir: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempCopy)
            return
        }
        defer { try? FileManager.default.removeItem(at: extractRoot) }

        do {
            try await Task.detached(priority: .userInitiated) { [extractRoot] in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                p.arguments = ["-q", tempCopy.path, "-d", extractRoot.path]
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    throw NSError(domain: "ModelManager.CoreML", code: Int(p.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "unzip exited \(p.terminationStatus)"])
                }
            }.value
        } catch {
            modelLogger.error("CoreML download \(model.name, privacy: .public): unzip failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempCopy)
            return
        }
        try? FileManager.default.removeItem(at: tempCopy)

        // Find the `.mlmodelc` directory inside the extracted tree (the
        // zip might wrap it in `<name>.mlmodelc/` or in a subdir — both
        // ggerganov and our HF repo use the flat layout, but be defensive).
        guard let mlmodelc = ModelManager.findMLModelcDirectory(in: extractRoot) else {
            modelLogger.error("CoreML download \(model.name, privacy: .public): no .mlmodelc directory inside the zip")
            return
        }

        if FileManager.default.fileExists(atPath: destDir.path) {
            try? FileManager.default.removeItem(at: destDir)
        }
        do {
            try FileManager.default.moveItem(at: mlmodelc, to: destDir)
            modelLogger.notice("CoreML download \(model.name, privacy: .public): installed at \(destDir.path, privacy: .public)")
        } catch {
            modelLogger.error("CoreML download \(model.name, privacy: .public): final move failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Recursively search `root` for the first `*.mlmodelc` directory.
    /// Skips `__MACOSX/` clutter from zips made on macOS Finder.
    nonisolated static func findMLModelcDirectory(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "mlmodelc",
               let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory,
               isDir {
                return url
            }
        }
        return nil
    }
}
