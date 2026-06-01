import Foundation
import AppKit
import Combine
import AVFoundation
import TranscriptionCore

/// Press the bound hotkey to start a dictation in that language. Press the same
/// hotkey again to stop, transcribe, and paste at the cursor.
///
/// English and Hebrew each have their own global hotkey (configurable in the
/// Settings UI; defaults `⌘2` and `⌘3`). Pressing the *other* language's
/// hotkey while one is in flight is ignored — the user has to stop the active
/// one first to avoid mid-sentence language flips that produce garbage
/// transcripts.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable { case idle, recording(HotkeyAction), transcribing(HotkeyAction) }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0
    /// The language of the *most recent* dictation, exposed so the toolbar
    /// button can label itself ("Dictate · EN" / "Dictate · HE"). Defaults
    /// to Hebrew on a fresh install to preserve the pre-rename UX.
    @Published private(set) var lastLanguage: String = "he"

    private let recorder = MicrophoneRecorder()
    private var samples: [Float] = []
    private var streamTask: Task<Void, Never>?

    /// Live transcriber used to surface partial transcripts in the
    /// dictation overlay AND to remove the post-release transcription
    /// wait. We rely on it being the *same instance* across dictations
    /// (it's reset at the start of every press via `start(language:)`).
    private let liveTranscriber: LiveTranscriber

    /// Observation of `liveTranscriber.segments` so the overlay can show
    /// the latest tentative text without the controller having to
    /// manually push every update.
    private var liveTextObserver: AnyCancellable?

    /// The app that was frontmost when this dictation started. Captured at
    /// `start(action:)` time and re-activated at `paste(_:)` time so the
    /// synthesized ⌘V always lands in the user's intended app — never in
    /// Mila itself, even if focus shifted to us during recording
    /// (e.g. the user clicked back into the Mila window mid-take).
    private var targetApp: NSRunningApplication?

    private let store: RecordingStore
    private let transcription: TranscriptionService
    private let hotkeySettings: HotkeySettings
    private var bindingsObserver: AnyCancellable?

    init(store: RecordingStore,
         transcription: TranscriptionService,
         hotkeySettings: HotkeySettings,
         liveTranscriber: LiveTranscriber) {
        self.store = store
        self.transcription = transcription
        self.hotkeySettings = hotkeySettings
        self.liveTranscriber = liveTranscriber
        registerHotkeys()
        bindingsObserver = hotkeySettings.$bindings
            .dropFirst()
            .sink { [weak self] _ in self?.registerHotkeys() }
    }

    // MARK: - Hotkey wiring

    private func registerHotkeys() {
        for action in HotkeyAction.allCases {
            let binding = hotkeySettings.binding(for: action)
            HotkeyManager.shared.register(action, binding: binding) { [weak self] in
                Task { await self?.toggle(action: action) }
            }
        }
    }

    // MARK: - Public API

    /// Toggle dictation for `action`. If a different action's dictation is
    /// already in flight, this call is ignored (we don't want to interleave
    /// languages).
    func toggle(action: HotkeyAction) async {
        switch state {
        case .idle:
            await start(action: action)
        case .recording(let active) where active == action:
            await stopAndTranscribe(action: action)
        case .recording, .transcribing:
            NSSound.beep()
        }
    }

    /// Stop any in-flight dictation immediately. Used by the AppDelegate
    /// during graceful shutdown.
    func cancelInFlight() async {
        guard case .recording = state else { return }
        await recorder.stop()
        streamTask?.cancel(); streamTask = nil
        liveTextObserver?.cancel(); liveTextObserver = nil
        _ = liveTranscriber.stop()
        samples.removeAll(keepingCapacity: true)
        targetApp = nil
        DictationOverlayWindow.shared.hide()
        state = .idle
        level = 0
    }

    // MARK: - Recording

    private func start(action: HotkeyAction) async {
        // Snapshot the user's frontmost app FIRST, before we touch any UI or
        // the audio engine. Even though our overlay is a non-activating
        // panel, the user might click into Mila mid-take, and we
        // need to know where to put the result regardless.
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != myPID {
            targetApp = frontmost
        } else {
            targetApp = nil
        }

        // Trigger the AX permission prompt on first dictation if we're not
        // trusted yet. This pops the system dialog + adds us to the
        // Accessibility list. macOS requires a relaunch after the user
        // toggles us on for trust to actually apply, so the first dictation
        // after install will still hit the missing-permission fallback path.
        if !AccessibilityPermission.isTrusted() {
            AccessibilityPermission.requestPromptIfNeeded()
        }

        guard await recorder.requestAccess() else {
            NSSound.beep()
            return
        }
        samples.removeAll(keepingCapacity: true)
        do {
            try await recorder.start()
        } catch {
            NSSound.beep()
            return
        }
        state = .recording(action)
        lastLanguage = action.languageCode
        DictationOverlayWindow.shared.show()
        DictationOverlayWindow.shared.setLanguage(action.languageCode)

        // Start the live transcriber so the overlay shows partial text
        // and the user doesn't wait for a one-shot pass on release.
        liveTranscriber.start(language: action.languageCode)
        liveTextObserver = liveTranscriber.$segments
            .receive(on: DispatchQueue.main)
            .sink { segments in
                let text = segments
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DictationOverlayWindow.shared.updateLiveText(text)
            }

        streamTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in self.recorder.audioStream {
                let chunk = AudioConvert.samples(from: buffer)
                let lvl = AudioMeter.level(from: buffer)
                await MainActor.run {
                    self.samples.append(contentsOf: chunk)
                    self.level = lvl
                    DictationOverlayWindow.shared.updateLevel(lvl)
                    self.liveTranscriber.ingest(chunk[0..<chunk.count])
                }
            }
        }
    }

    private func stopAndTranscribe(action: HotkeyAction) async {
        await recorder.stop()
        streamTask?.cancel(); streamTask = nil
        state = .transcribing(action)
        DictationOverlayWindow.shared.setBusy(true)

        let captured = samples
        samples.removeAll(keepingCapacity: true)
        liveTextObserver?.cancel()
        liveTextObserver = nil
        _ = liveTranscriber.stop()

        // ALWAYS do a final one-shot pass over the full captured audio.
        // We tried using `LiveTranscriber.formattedTranscript` as the
        // authoritative paste text, but that's a snapshot of the
        // sliding-window state — it only contains the last ~20 seconds
        // of audio because earlier windows aged out. A 60-second
        // dictation pasted as the last ~20 seconds. The live transcriber
        // stays around purely for the overlay's "watch your words
        // appear" UX; the FINAL text comes from one whisper pass over
        // every sample we captured.
        //
        // `audioCtx: 0` opts out of WhisperEngine's live-VAD-tuned
        // audio_ctx truncation. Dictation clips are hotkey-bounded
        // (sub-second to a few seconds) and we don't have a labelled
        // fixture set for that distribution — the CI e2e sweep on
        // ggml-tiny showed short-clip WER regressions under truncation
        // (en_numbers_and_dates 5.17s, 0.29 → 0.36). Use whisper's
        // default 1500-token (= 30s) context to preserve baseline
        // quality for dictation.
        let text = await transcription.transcribeOnce(samples: captured,
                                                      language: action.languageCode,
                                                      audioCtx: 0)

        DictationOverlayWindow.shared.hide()
        state = .idle
        level = 0

        if !text.isEmpty {
            paste(text)
        } else {
            NSSound.beep()
        }

        await persistDictation(samples: captured, text: text, action: action)
    }

    // MARK: - Persistence

    /// Save the dictation as a Recording so it shows up under History → Dictations.
    private func persistDictation(samples: [Float],
                                  text: String,
                                  action: HotkeyAction) async {
        guard !samples.isEmpty else { return }
        let url = store.freshAudioURL(suggestedName: "Dictation")
        do {
            let format = WhisperAudioFormat.pcmFloat32
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            if let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(samples.count)) {
                buffer.frameLength = AVAudioFrameCount(samples.count)
                if let channel = buffer.floatChannelData?[0] {
                    samples.withUnsafeBufferPointer { src in
                        channel.update(from: src.baseAddress!, count: samples.count)
                    }
                }
                try file.write(from: buffer)
            }
        } catch {
            print("Dictation save error: \(error)")
            return
        }
        let title = "Dictation · \(Self.titleFormatter.string(from: Date()))"
        let recording = Recording(
            title: title,
            duration: Double(samples.count) / WhisperAudioFormat.sampleRate,
            source: .microphone,
            audioFileName: url.lastPathComponent,
            status: text.isEmpty ? .failed : .completed,
            language: action.languageCode,
            segments: text.isEmpty ? [] : [.init(start: 0, end: 0, text: text)],
            fullText: text
        )
        store.add(recording)
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Paste

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let priorContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Without Accessibility trust, CGEvent.post is silently dropped by
        // macOS — the user would see "I dictated, nothing happened" with no
        // explanation. Surface a one-shot alert and leave the text on the
        // clipboard so they can paste manually with ⌘V.
        guard AccessibilityPermission.isTrusted() else {
            AccessibilityPermission.notifyMissing()
            // Do NOT restore the prior clipboard contents — the transcript
            // is the user's only path to the dictated text right now.
            targetApp = nil
            return
        }

        // Re-activate the user's intended app so the synthesized ⌘V lands
        // there instead of in Mila itself. If the captured target
        // is gone (quit during recording) we fall through and the paste
        // hits whatever app is currently frontmost — best effort.
        let captured = targetApp
        targetApp = nil
        if let target = captured, !target.isTerminated, !target.isActive {
            target.activate()
        }

        // Give the OS ~120ms to actually move focus to the target app
        // before posting the keystrokes; otherwise the synthesized events
        // can race the activation and land in the previously-frontmost
        // window instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) {
            Self.postCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let prior = priorContents {
                    pasteboard.clearContents()
                    pasteboard.setString(prior, forType: .string)
                }
            }
        }
    }

    /// Synthesize a Cmd+V at the HID event-tap level. Requires the process
    /// to be Accessibility-trusted; the caller is responsible for that
    /// check (see `AccessibilityPermission.isTrusted()`).
    private static func postCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let vUp     = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        // Some apps inspect the event flags rather than the global modifier
        // state. Setting the Command flag on every event in the sequence is
        // the most defensive thing we can do.
        cmdDown?.flags = .maskCommand
        vDown?.flags   = .maskCommand
        vUp?.flags     = .maskCommand
        cmdUp?.flags   = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
