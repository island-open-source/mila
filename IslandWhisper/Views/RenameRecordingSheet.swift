import SwiftUI

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

    @State private var title: String
    @State private var isFetchingName = false
    @State private var llmError: String?
    /// One-shot guard so the auto-suggest doesn't re-fire every time the
    /// store publishes (transcript edits, status flips, etc.).
    @State private var didAutoSuggest = false

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

    /// "Transcribing…", "Done", "Failed", "Waiting in queue" — drives the
    /// progress indicator inside the sheet.
    private var transcriptionLabel: String {
        let live = liveRecording
        if transcription.activeRecordingID == live.id {
            let pct = Int(transcription.progress * 100)
            return "Transcribing… \(pct)%"
        }
        switch live.status {
        case .pending:   return "Waiting to transcribe…"
        case .running:   return "Transcribing…"
        case .completed: return "Transcript ready"
        case .failed:    return "Transcription failed"
        }
    }

    var body: some View {
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

            if let llmError {
                Text(llmError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // Cancel = throw the recording away entirely (and any
                // in-flight LLM call + active whisper transcription). See
                // PostRecordingCoordinator.cancelAndDiscard for the full
                // teardown.
                Button("Cancel") { coordinator.cancelAndDiscard() }
                    .keyboardShortcut(.cancelAction)
                if llm.isConfigured && llm.postActionEnabled {
                    Button("Save") { save() }
                    Button("Send to \(llm.tool.displayName)") { saveAndSend() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!transcriptReady)
                        .help(transcriptReady
                              ? "Save the title and run your action in the background"
                              : "Available once the transcript is ready")
                } else {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { triggerAutoSuggestIfReady() }
        .onChange(of: liveRecording.status) { _, _ in triggerAutoSuggestIfReady() }
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
        switch liveRecording.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private func save() {
        coordinator.dismiss(savingTitle: title)
    }

    /// Save the title, dismiss the sheet, then run the action in the
    /// background. We never block the UI on the LLM here — that's the whole
    /// point of "Send": the user expects to get on with their day, and the
    /// activity banner reports success / failure when the CLI returns.
    private func saveAndSend() {
        let toolName = llm.tool.displayName
        let prompt = llm.postActionPrompt
        let transcriptSnapshot = transcript
        let executableOverride = llm.executablePath.isEmpty ? nil : llm.executablePath
        let tool = llm.tool
        coordinator.dismiss(savingTitle: title)
        coordinator.postStatus("Sending to \(toolName)…")
        Task.detached(priority: .utility) {
            do {
                let output = try await LLMRunner.run(
                    tool: tool,
                    prompt: prompt,
                    transcript: transcriptSnapshot,
                    executablePathOverride: executableOverride,
                    timeout: LLMRunner.defaultTimeout
                )
                let preview = output
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(80)
                await MainActor.run {
                    coordinator.postStatus("\(toolName): \(preview)")
                }
                print("LLMRunner: \(toolName) succeeded -> \(output.count) chars")
            } catch {
                await MainActor.run {
                    coordinator.postStatus("\(toolName) failed: \(error.localizedDescription)",
                                           isError: true)
                }
            }
        }
    }

    private func fetchNameFromLLM(auto: Bool = false) async {
        llmError = nil
        isFetchingName = true
        if auto { didAutoSuggest = true }
        defer { isFetchingName = false }
        do {
            // Foreground suggest gets a tighter timeout (90s) so a hung CLI
            // doesn't pin the sheet for 5 minutes. Background "Send" uses
            // the full 5-min default.
            let suggestion = try await LLMRunner.run(
                tool: llm.tool,
                prompt: llm.namePrompt,
                transcript: transcript,
                executablePathOverride: llm.executablePath.isEmpty ? nil : llm.executablePath,
                timeout: 90
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
