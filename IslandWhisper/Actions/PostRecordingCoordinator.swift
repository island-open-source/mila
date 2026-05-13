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

    /// LLM work spawned from inside the rename sheet (auto-suggest, manual
    /// Suggest, Send-to-Claude). Tracked here — not in the sheet's view
    /// state — so the Cancel button can kill it even after the sheet is
    /// torn down, and so the in-flight handle survives the SwiftUI redraws
    /// that would otherwise re-create local `@State`.
    private var llmTasks: [UUID: Task<Void, Never>] = [:]

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

    /// Register a background LLM task so a later Cancel can cancel it. Any
    /// previously-tracked task for the same recording is replaced (and
    /// cancelled — there's no use case for two LLM calls competing for the
    /// same sheet).
    func trackLLM(_ task: Task<Void, Never>, for recordingID: UUID) {
        llmTasks[recordingID]?.cancel()
        llmTasks[recordingID] = task
    }

    /// Forget the tracked LLM task for `recordingID` without cancelling it.
    /// Called when the task ran to completion on its own, so we don't hold
    /// on to dead handles.
    func clearLLM(for recordingID: UUID) {
        llmTasks[recordingID] = nil
    }

    /// The Cancel button in the rename sheet: throw away EVERYTHING related
    /// to this recording. The user's mental model is "I changed my mind" —
    /// transcription that's still running keeps burning CPU on a result they
    /// won't see, and the foreground/background LLM call keeps running
    /// against the user's CLI auth quota. So:
    ///  1. cancel any in-flight LLM task (terminating the underlying CLI
    ///     process via LLMRunner's task-cancellation handler)
    ///  2. trip the transcription service's abort flag so whisper.cpp
    ///     unwinds within ~100ms instead of finishing
    ///  3. permanently delete the recording + its audio file
    ///  4. dismiss the sheet
    func cancelAndDiscard() {
        guard let recording = pending else { pending = nil; return }
        if let task = llmTasks.removeValue(forKey: recording.id) {
            task.cancel()
        }
        transcription.cancel(recordingID: recording.id)
        if let stored = store.recordings.first(where: { $0.id == recording.id }) {
            store.permanentlyDelete(stored)
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
