import Foundation
import Combine

/// Owns the "Name this recording" sheet lifecycle. The sheet pops the moment
/// a recording is added (i.e. recording stopped) — NOT when transcription
/// finishes — so the user can already type a title while Whisper is still
/// chewing on the audio. The sheet watches the store for the transcript and
/// enables LLM-driven suggest / send buttons once the text is available.
@MainActor
final class PostRecordingCoordinator: ObservableObject {
    /// The recording the rename sheet is currently bound to, if any.
    @Published var pending: Recording?

    /// One-shot status messages from background LLM actions ("Sent to
    /// Claude", "Send to Cursor failed: …"). ContentView renders these as a
    /// brief banner.
    @Published var activityStatus: String?
    @Published var activityIsError: Bool = false

    private let store: RecordingStore
    private let transcription: TranscriptionService

    init(store: RecordingStore, transcription: TranscriptionService) {
        self.store = store
        self.transcription = transcription
    }

    /// Open the rename sheet for a freshly-added recording. Called by
    /// QuickActionsController right after `store.add(...)`. Idempotent: if
    /// the sheet is already showing a different recording the new one is
    /// dropped (we don't queue — concurrent voice memos are rare and a
    /// stack of sheets is worse UX than just naming the first one).
    func present(_ recording: Recording) {
        guard pending == nil else { return }
        pending = recording
    }

    /// Persist a user-supplied title and dismiss. `nil` / blank title means
    /// "keep whatever's there".
    func dismiss(savingTitle newTitle: String? = nil) {
        if let recording = pending,
           let trimmed = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty,
           var updated = store.recordings.first(where: { $0.id == recording.id }),
           trimmed != updated.title {
            updated.title = trimmed
            store.update(updated)
        }
        pending = nil
    }

    /// Set a transient status message visible to the user. Auto-clears
    /// after a few seconds.
    func postStatus(_ message: String, isError: Bool = false) {
        activityStatus = message
        activityIsError = isError
        let snapshot = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            if self.activityStatus == snapshot {
                self.activityStatus = nil
                self.activityIsError = false
            }
        }
    }
}
