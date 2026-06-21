import SwiftUI

/// Sheet shown when the user right-clicks a recording and picks
/// "Send to <LLM>…". Surfaces the prompt that will be sent (editable for
/// one-off tweaks — defaults to `LLMSettings.postActionPrompt`) and a
/// read-only preview of the transcript, then runs the LLM call in the
/// background just like the RenameRecordingSheet's "Send" path.
struct SendToLLMSheet: View {
    let recording: Recording

    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var llm: LLMSettings
    @EnvironmentObject private var postRecording: PostRecordingCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""

    /// What this send ships — seeded from the global default
    /// (`llm.sendContent`) on appear, then editable per-send.
    @State private var sendContent: LLMSendContent = .transcript

    /// Live recording from the store so an in-flight re-transcription
    /// updates the preview without the sheet needing to be reopened.
    private var liveRecording: Recording {
        store.recordings.first(where: { $0.id == recording.id }) ?? recording
    }

    private var transcript: String {
        TranscriptFormatter.plainText(segments: liveRecording.segments,
                                      fallback: liveRecording.fullText)
    }

    private var summary: String {
        (liveRecording.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var actionItemTexts: [String] {
        (liveRecording.actionItems ?? [])
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The actual transcript / summary / action-items triple that will be
    /// sent, resolved from the per-send `sendContent` picker.
    ///
    /// In `.summaryAndActionItems` mode we ship the summary + action items and
    /// drop the transcript — *unless* both are empty (e.g. the recording ran
    /// without Live AI), in which case we fall back to sending the transcript
    /// so the send is never empty. The `.transcript` default sends the
    /// transcript and the summary (the long-standing behaviour), no items.
    private var resolvedPayload: (transcript: String, summary: String, actionItems: [String]) {
        switch sendContent {
        case .transcript:
            return (transcript, summary, [])
        case .summaryAndActionItems:
            if summary.isEmpty && actionItemTexts.isEmpty {
                // Fallback: nothing to summarise — send the transcript so the
                // send still carries content.
                return (transcript, "", [])
            }
            return ("", summary, actionItemTexts)
        }
    }

    /// True when the resolved payload has *something* to send. The Send button
    /// gates on this rather than on the raw transcript, so summary-only sends
    /// (transcript still in flight) are allowed.
    private var hasContentToSend: Bool {
        let p = resolvedPayload
        return !p.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !p.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !p.actionItems.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            contentPicker
            promptEditor
            contentPreview
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send to \(llm.tool.displayName)") { send() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasContentToSend || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 540)
        .onAppear {
            // Seed with the saved action prompt; user can edit just for this
            // run without overwriting Settings.
            if prompt.isEmpty {
                prompt = llm.postActionPrompt
            }
            // Seed the per-send content choice from the global default.
            sendContent = llm.sendContent
        }
        .accessibilityIdentifier("sendtollm.sheet")
    }

    /// Header verb tracks what will actually be sent: "transcript" for the
    /// default mode, "summary" once the summary+items mode resolves to a
    /// non-empty summary/items payload, and back to "transcript" when that
    /// mode falls back (no Live-AI content).
    private var header: some View {
        let noun: String = {
            switch sendContent {
            case .transcript: return "transcript"
            case .summaryAndActionItems:
                return (summary.isEmpty && actionItemTexts.isEmpty) ? "transcript" : "summary"
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text("Send \(noun) to \(llm.tool.displayName)")
                .font(.title3.weight(.semibold))
            Text(liveRecording.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var contentPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Send", selection: $sendContent) {
                Text("Transcript").tag(LLMSendContent.transcript)
                Text("Summary & action items").tag(LLMSendContent.summaryAndActionItems)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("sendtollm.content.picker")
            if sendContent == .summaryAndActionItems && summary.isEmpty && actionItemTexts.isEmpty {
                Text("No summary or action items for this recording (Live AI was off) — the transcript will be sent instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prompt").font(.callout.weight(.semibold))
                Spacer()
                Button("Reset to saved") {
                    prompt = llm.postActionPrompt
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(prompt == llm.postActionPrompt)
            }
            TextEditor(text: $prompt)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .accessibilityIdentifier("sendtollm.prompt.field")
        }
    }

    /// Preview reflects the *resolved* payload, not the raw transcript, so the
    /// user sees exactly what the LLM will receive for the current mode.
    private var contentPreview: some View {
        let payload = resolvedPayload
        let body: String = {
            var parts: [String] = []
            if !payload.summary.isEmpty {
                parts.append("Summary:\n\(payload.summary)")
            }
            if !payload.actionItems.isEmpty {
                parts.append("Action items:\n" + payload.actionItems.map { "- \($0)" }.joined(separator: "\n"))
            }
            if !payload.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let label = (payload.summary.isEmpty && payload.actionItems.isEmpty) ? "Transcript" : "Full transcript"
                parts.append("\(label):\n\(payload.transcript)")
            }
            return parts.joined(separator: "\n\n")
        }()
        let isEmpty = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.callout.weight(.semibold))
            ScrollView {
                Text(isEmpty ? "(nothing to send yet — wait for the recording to finish, then try again)" : body)
                    .font(.system(.callout))
                    .foregroundStyle(isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .background(Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("sendtollm.preview")
        }
    }

    private func send() {
        let recordingID = liveRecording.id
        let promptSnapshot = prompt
        // Snapshot the payload resolved from the per-send content picker:
        //  * .transcript          → transcript + summary (gist above raw text)
        //  * .summaryAndActionItems → summary + action items, no transcript
        //    (falls back to transcript when both are empty)
        // LLMRunner.composedPrompt collapses any empty sections, so an
        // empty summary / items just drops back to the old wire format.
        let payload = resolvedPayload
        let executableOverride = llm.executablePath.isEmpty ? nil : llm.executablePath
        let tool = llm.tool
        dismiss()
        // Hand off to the app-lifetime coordinator so the call is owned +
        // cancellable rather than spawned as a fire-and-forget detached
        // Task. The Send button here is already gated on a non-empty
        // payload, so the coordinator runs it immediately (no transcript
        // wait) — except for the summary/items mode, whose deliberately
        // empty transcript the coordinator knows not to wait on.
        postRecording.sendToLLM(recordingID: recordingID,
                                tool: tool,
                                prompt: promptSnapshot,
                                transcript: payload.transcript,
                                summary: payload.summary,
                                actionItems: payload.actionItems,
                                executableOverride: executableOverride)
    }
}
