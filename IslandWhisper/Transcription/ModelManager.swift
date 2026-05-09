import Foundation
import Combine

/// Catalog of supported ggml models. Add more here as needed.
struct WhisperModel: Identifiable, Hashable, Codable {
    var id: String { name }
    var name: String
    var displayName: String
    var url: URL
    var sizeBytes: Int64
    var languageHint: String

    /// Hebrew default. The full ivrit.ai `large-v3` finetune (~3 GB, ~2x
    /// slower than the turbo variant). Empirically noticeably more accurate
    /// than the turbo finetune on Hebrew speech, which is why we ship it as
    /// the default despite the size and latency cost.
    static let ivritLarge = WhisperModel(
        name: "ivrit-ai-whisper-large-v3",
        displayName: "ivrit.ai · large-v3 (Hebrew)",
        url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-ggml/resolve/main/ggml-model.bin")!,
        sizeBytes: 3_094_023_488,
        languageHint: "he"
    )

    /// English (and any other multilingual) default. As of mid-2026 this is
    /// the open-weights state of the art for English at this size class —
    /// faster than full `large-v3` for essentially identical English WER, and
    /// it's the same checkpoint Whisper.cpp ship by default.
    static let openaiTurbo = WhisperModel(
        name: "openai-whisper-large-v3-turbo",
        displayName: "OpenAI · large-v3-turbo (English / multilingual)",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        sizeBytes: 1_624_555_275,
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
        try? FileManager.default.moveItem(at: location, to: tempCopy)
        Task { @MainActor in
            guard let model = self.observers.removeValue(forKey: id) else { return }
            let dest = self.url(for: model)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempCopy, to: dest)
            } catch {
                print("Move failed: \(error)")
            }
            self.downloads.removeValue(forKey: model.name)
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
                print("Download \(model.name) failed: \(error)")
            }
        }
    }
}
