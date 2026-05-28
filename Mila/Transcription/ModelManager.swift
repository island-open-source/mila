import Foundation
import Combine
import CryptoKit
import os.log

private let modelLogger = Logger(subsystem: "io.island.mila.Mila",
                                 category: "models")

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
        languageHint: "he"
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
        languageHint: "en"
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
        let best = WhisperModel.bestModel(for: languageCode)
        if isInstalled(best) { return best }
        return selectedModel().flatMap { isInstalled($0) ? $0 : nil } ?? best
    }

    func url(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent("\(model.name).bin")
    }

    func isInstalled(_ model: WhisperModel) -> Bool {
        installed.contains(model.name)
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
            guard let model = self.observers[id] else { return }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.sizeBytes
            let progress = Double(totalBytesWritten) / Double(total)
            self.downloads[model.name] = max(0, min(1, progress))
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
            guard let model = self.observers.removeValue(forKey: id) else { return }
            // Keep `downloads[model.name]` set until we're truly done (verified
            // AND installed, or failed) — otherwise during the multi-second
            // off-main hash the duplicate-download guard in `download(_:)` and
            // the auto-download check in `ensureDefaultModelsInstalled` both
            // see no in-flight download and can kick off a redundant fetch of
            // the same 3 GB file.
            defer { self.downloads.removeValue(forKey: model.name) }
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
            }
        }
    }
}
