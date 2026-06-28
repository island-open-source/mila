import SwiftUI
import AppKit

/// Shown the moment a recording is added — i.e. as soon as recording stops,
/// in parallel with transcription. The user can type a title and Save at any
/// time; the Suggest / Send buttons stay disabled until the transcript is
/// available, and (if the user keeps "Auto-suggest" checked) Suggest fires
/// automatically once the text lands.
struct RenameRecordingSheet: View {
    let initialRecording: Recording

    @EnvironmentObject private var coordinator: PostRecordingCoordinator
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var llm: LLMSettings
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var summarizer: RecordingSummarizer

    @State private var title: String
    @State private var isFetchingName = false
    @State private var llmError: String?
    /// One-shot guard so the auto-suggest doesn't re-fire every time the
    /// store publishes (transcript edits, status flips, etc.).
    @State private var didAutoSuggest = false
    /// Confirmation gate before the destructive Discard button actually
    /// throws the recording away. Closing the sheet (ESC, X, app quit)
    /// always saves — discarding requires an explicit click + confirm,
    /// because the user's mental model is "I just recorded something,
    /// don't lose it."
    @State private var confirmingDiscard = false
    /// Persists the user's "show prompts" preference across sheet sessions.
    /// Most people glance at the prompt once and then collapse it; we
    /// remember that choice so the disclosure doesn't snap open every time
    /// the rename sheet appears.
    @AppStorage("rename.showLLMPrompts") private var showLLMPrompts: Bool = false

    init(initialRecording: Recording) {
        self.initialRecording = initialRecording
        _title = State(initialValue: initialRecording.title)
    }

    /// Live recording (transcript fills in here as Whisper finishes).
    private var liveRecording: Recording {
        store.recordings.first(where: { $0.id == initialRecording.id }) ?? initialRecording
    }

    /// Speaker-aware view of the transcript. When diarization produced
    /// labels, each turn comes through as `SPEAKER_XX: …` so the LLM (or
    /// any other consumer of this property) sees who said what, not just
    /// a wall of concatenated text. Falls back to the plain `fullText`
    /// join when no segments carry speaker info.
    private var transcript: String {
        TranscriptFormatter.plainText(segments: liveRecording.segments,
                                      fallback: liveRecording.fullText)
    }
    private var transcriptReady: Bool {
        !transcript.isEmpty && liveRecording.status != .running && liveRecording.status != .pending
    }

    /// Live-AI summary attached to the recording (captured at stop time).
    /// Empty string when Live AI wasn't running for this recording — the
    /// summary block below renders nothing in that case.
    private var summary: String {
        (liveRecording.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Action items captured by Live AI. Empty list collapses the section.
    private var actionItems: [ActionItem] {
        liveRecording.actionItems ?? []
    }

    private var hasAIOverview: Bool {
        !summary.isEmpty
            || !actionItems.isEmpty
            // Still surface the section while a backfill / regenerate
            // call is in flight so the user sees the "Summarizing…"
            // spinner instead of an empty card.
            || summarizer.isSummarizing(liveRecording.id)
    }

    /// "Transcribing…", "Identifying speakers…", "Done", "Failed",
    /// "Waiting in queue" — drives the progress indicator inside the sheet.
    private var transcriptionLabel: String {
        let live = liveRecording
        if transcription.activeRecordingID == live.id {
            let pct = Int(transcription.progress * 100)
            return "Transcribing… \(pct)%"
        }
        // The offline re-diarize pass: the transcript text is already final
        // (status is .completed), so "Transcribing" would be wrong — the
        // pyannote subprocess is only re-clustering speaker labels.
        if transcription.diarizingRecordingID == live.id {
            return "Identifying speakers…"
        }
        switch live.status {
        case .pending:   return "Waiting to transcribe…"
        case .running:   return "Transcribing…"
        case .completed: return "Transcript ready"
        case .failed:    return "Transcription failed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed top: identity + status. Never scrolls, so the title field
            // and "transcribing…" status are always visible.
            VStack(alignment: .leading, spacing: 16) {
                header

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.callout.weight(.semibold))
                    HStack {
                        TextField("Recording title", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { save() }
                        if llm.isConfigured && llm.nameGenerationEnabled {
                            Button {
                                startFetchName(auto: false)
                            } label: {
                                if isFetchingName {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Suggest", systemImage: "sparkles")
                                }
                            }
                            .disabled(isFetchingName || !transcriptReady)
                            .help(transcriptReady
                                  ? "Ask \(llm.tool.displayName) for a title"
                                  : "Available once the transcript is ready")
                        }
                    }
                }

                transcriptionStatus
            }
            .padding(20)

            // Scrollable middle: the AI summary + action items + LLM prompt
            // can be arbitrarily long. Cap the height and scroll inside it so
            // a long summary can never push the footer buttons off-screen —
            // that was the "can't reach Save/Discard" bug. Mirrors the
            // ScrollView+maxHeight pattern already used in RecordingDetailView.
            if hasAIOverview || llm.isConfigured || llmError != nil {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if hasAIOverview {
                            aiOverviewSection
                        }
                        if llm.isConfigured {
                            llmPromptDisclosure
                        }
                        if let llmError {
                            Text(llmError)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }

            Divider()

            // Fixed footer: Save/Discard are pinned here, always reachable
            // regardless of summary length.
            HStack {
                // Destructive opt-out: throws the recording away entirely
                // (and any in-flight LLM call + active whisper
                // transcription). Gated behind a confirm because the
                // previous "Cancel" copy was hit accidentally — losing
                // a just-finished recording was the #1 user complaint.
                // ESC no longer triggers this (we route ESC -> save
                // below); the user must click and confirm.
                Button(role: .destructive) {
                    confirmingDiscard = true
                } label: {
                    Text("Discard")
                }
                .help("Permanently delete this recording and stop transcribing it")
                Spacer()
                if llm.isConfigured && llm.postActionEnabled {
                    Button("Save") { save() }
                    // Always enabled — pressing this saves, dismisses, and
                    // runs the action in the BACKGROUND, exactly like Save.
                    // It used to be `.disabled(!transcriptReady)`, which
                    // forced the user to wait for transcription with the
                    // sheet open before they could "fire and walk away".
                    // The coordinator now waits for the transcript itself
                    // when fired early, so the button never needs to gate.
                    Button("Send to \(llm.tool.displayName)") { saveAndSend() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .help("Save the title and run your action in the background")
                } else {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 480)
        // ESC = save and close. Without this, ESC has no binding and the
        // sheet stays modal until the user clicks. We deliberately do NOT
        // bind ESC to Discard — the whole point of this change is that
        // dismissing the sheet must never throw audio away.
        .onExitCommand { save() }
        .onAppear { triggerAutoSuggestIfReady() }
        .onChange(of: liveRecording.status) { _, _ in triggerAutoSuggestIfReady() }
        .confirmationDialog("Discard this recording?",
                            isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                coordinator.cancelAndDiscard()
            }
            Button("Keep", role: .cancel) { }
        } message: {
            Text("The audio file and any transcript will be permanently deleted.")
        }
    }

    /// Auto-fire the LLM Suggest call as soon as the transcript is ready,
    /// gated solely by the Settings toggle. The user does not get a
    /// per-recording opt-out in the sheet — keeping that preference in one
    /// place avoids "did I check the box?" confusion.
    private func triggerAutoSuggestIfReady() {
        guard llm.isConfigured,
              llm.nameGenerationEnabled,
              transcriptReady,
              !didAutoSuggest,
              !isFetchingName else { return }
        startFetchName(auto: true)
    }

    /// Wrap `fetchNameFromLLM` in a Task tracked by the coordinator so the
    /// rename-sheet's Cancel button can kill it (the auto-suggest path is
    /// where users were most surprised that "things keep running" after
    /// Cancel). Auto-clears its own handle on completion so we don't keep
    /// dead Task references around.
    private func startFetchName(auto: Bool) {
        let recordingID = liveRecording.id
        let task = Task { @MainActor in
            await fetchNameFromLLM(auto: auto)
            coordinator.clearLLM(for: recordingID)
        }
        coordinator.trackLLM(task, for: recordingID)
    }

    /// Collapsible block that shows the LLM prompt(s) the buttons in this
    /// sheet will send. Surfaces what's about to be done with the transcript
    /// (helpful for first-time users + when you forget what prompt you saved
    /// in Settings) without cluttering the sheet for daily-driver users —
    /// they keep it collapsed and the chevron rotates as a hint.
    private var llmPromptDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    showLLMPrompts.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showLLMPrompts ? 90 : 0))
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Text(showLLMPrompts
                         ? "Hide \(llm.tool.displayName) prompt"
                         : "Show \(llm.tool.displayName) prompt")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rename.llmprompt.toggle")

            if showLLMPrompts {
                VStack(alignment: .leading, spacing: 10) {
                    if llm.nameGenerationEnabled {
                        promptBlock(label: "Suggest name",
                                    text: llm.namePrompt)
                    }
                    if llm.postActionEnabled {
                        promptBlock(label: "Send to \(llm.tool.displayName)",
                                    text: llm.postActionPrompt)
                    }
                    if !llm.nameGenerationEnabled && !llm.postActionEnabled {
                        Text("No prompts enabled. Turn on Suggest a name or Run an action in Settings → LLM.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func promptBlock(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "(empty)" : text)
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name this recording").font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Label(liveRecording.source.displayName,
                      systemImage: liveRecording.source.sfSymbol)
                Text("·")
                Text(formatDuration(liveRecording.duration))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// Summary + action items captured by Live AI during the recording.
    /// Wraps the shared `AIOverviewSection` (used by RecordingDetailView
    /// too) in a `.regularMaterial` card so the rename sheet's
    /// post-record summary feels distinct from the form fields above
    /// it without diverging from the detail screen's content layout.
    /// Bugbot finding on PR #25 — the inner content used to be a
    /// duplicated near-copy of `AIOverviewSection`; both call sites
    /// now feed the same view, only the chrome differs.
    @ViewBuilder
    private var aiOverviewSection: some View {
        AIOverviewSection(
            summary: summary,
            items: actionItems,
            recordingLanguage: liveRecording.language,
            onRegenerateSummary: canRegenerateSummary
                ? { summarizer.regenerate(liveRecording) }
                : nil,
            isSummarizing: summarizer.isSummarizing(liveRecording.id)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Same gating logic as the detail view's: the user can ask for a
    /// fresh summary as long as their LLM CLI is configured and we
    /// have a non-empty transcript to feed it.
    private var canRegenerateSummary: Bool {
        guard llm.isConfigured else { return false }
        return !liveRecording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    @ViewBuilder
    private var transcriptionStatus: some View {
        HStack(spacing: 10) {
            statusIcon
            Text(transcriptionLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            if transcription.activeRecordingID == liveRecording.id {
                ProgressView(value: transcription.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 140)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        // While the offline re-diarize is in flight the transcript is done
        // but speaker labels aren't — show a spinner, not the green check,
        // to match the "Identifying speakers…" label.
        if transcription.diarizingRecordingID == liveRecording.id {
            ProgressView().controlSize(.small)
        } else {
            switch liveRecording.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            default:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func save() {
        coordinator.dismiss(savingTitle: title)
    }

    /// Save the title, dismiss the sheet, then run the action in the
    /// background. We never block the UI on the LLM here — that's the whole
    /// point of "Send": the user expects to get on with their day, and the
    /// activity banner reports success / failure when the CLI returns.
    ///
    /// The actual send is owned by `PostRecordingCoordinator` (an
    /// app-lifetime object) rather than a bare `Task.detached` here, so
    /// the call survives the sheet being torn down and `cancelAndDiscard`
    /// can cancel it. We snapshot the prompt/transcript/summary first
    /// (they're tied to this `liveRecording`) and hand them off; the
    /// transcript snapshot may be empty if the user pressed Send before
    /// transcription finished — the coordinator waits for it in that case.
    private func saveAndSend() {
        let recordingID = liveRecording.id
        let prompt = llm.postActionPrompt
        let transcriptSnapshot = transcript
        // Summary travels alongside the transcript so the LLM sees the
        // gist (already condensed by Live AI) before the raw text. When
        // Live AI wasn't running this is "" and LLMRunner.composedPrompt
        // omits the Summary section entirely — back-compat with the old
        // transcript-only callers.
        let summarySnapshot = summary
        let executableOverride = llm.executablePath.isEmpty ? nil : llm.executablePath
        let tool = llm.tool
        coordinator.dismiss(savingTitle: title)
        coordinator.sendToLLM(recordingID: recordingID,
                              tool: tool,
                              prompt: prompt,
                              transcript: transcriptSnapshot,
                              summary: summarySnapshot,
                              executableOverride: executableOverride,
                              cliTimeout: llm.cliTimeout)
    }

    private func fetchNameFromLLM(auto: Bool = false) async {
        llmError = nil
        isFetchingName = true
        if auto { didAutoSuggest = true }
        defer { isFetchingName = false }
        do {
            let suggestion = try await LLMRunner.run(
                tool: llm.tool,
                prompt: llm.namePrompt,
                transcript: transcript,
                executablePathOverride: llm.executablePath.isEmpty ? nil : llm.executablePath,
                timeout: llm.cliTimeout
            )
            let cleaned = suggestion
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`."))
            if cleaned.isEmpty {
                throw LLMRunnerError.emptyOutput
            }
            // Take the first line — some CLIs preface or append commentary
            // even when asked for a bare title. The first non-empty line is
            // almost always the intended answer.
            let firstLine = cleaned.split(whereSeparator: \.isNewline)
                .first.map(String.init) ?? cleaned
            title = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`. "))
        } catch LLMRunnerError.cancelled {
            // User clicked Cancel — the sheet is about to be torn down. No
            // banner, no error state.
        } catch {
            // Same idea as above for Swift's CancellationError, which surfaces
            // when withTaskCancellationHandler's onCancel beat us to it.
            if Task.isCancelled { return }
            llmError = error.localizedDescription
        }
    }
}
