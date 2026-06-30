import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class TranscriptionServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!

    private var savedSelection: String?

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "TranscriptionServiceTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        store = RecordingStore(rootDirectory: tempRoot)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        savedSelection = UserDefaults.standard.string(forKey: "selectedModelName")
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        service = TranscriptionService(store: store, modelManager: manager, diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServiceTests.diarization")!), engine: stub)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: "selectedModelName")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedModelName")
        }
        try await super.tearDown()
    }

    // MARK: - Remote backend error surfacing
    //
    // Regression coverage for the silent-failure bug: a remote backend with a
    // bad key (or unreachable endpoint) used to empty the live transcript with
    // NO visible error — the failure only appeared on the Stop batch pass, and
    // CI never caught it because the remote E2E suite only tested the happy
    // path against an accepting mock. These tests pin the two new guards.

    func test_probeRemoteBackendIfActive_isNoopForLocalBackend() async {
        // The default `service` uses the on-device backend. Probing must do
        // nothing — never touch the network or the Keychain, never error.
        XCTAssertNil(service.lastError)
        await service.probeRemoteBackendIfActive()
        XCTAssertNil(service.lastError, "Local backend must not be probed")
    }

    func test_probeRemoteBackendIfActive_surfacesAuthFailure() async {
        // The record-start probe must turn a 401 into an immediate, actionable
        // error instead of a blank live pane discovered 13 minutes later.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Probe401URLProtocol.self]
        let session = URLSession(configuration: config)
        let suite = UserDefaults(suiteName: "TranscriptionServiceTests.probe401")!
        suite.removePersistentDomain(forName: "TranscriptionServiceTests.probe401")
        let keychainKey = "TranscriptionServiceTests.probe401.apiKey"
        defer { KeychainHelper.delete(key: keychainKey) }
        let remote = RemoteTranscriptionSettings(
            defaults: suite, urlSession: session, apiKeyKeychainKey: keychainKey)
        remote.backend = .remote
        remote.endpoint = "https://api.openai.com/v1"
        remote.apiKey = "test-key-123"
        let svc = TranscriptionService(
            store: store, modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServiceTests.probe401.diar")!),
            remoteSettings: remote, engine: StubWhisperEngine())

        XCTAssertNil(svc.lastError)
        await svc.probeRemoteBackendIfActive()
        XCTAssertNotNil(svc.lastError, "A 401 at record-start must surface immediately")
        XCTAssertTrue(svc.lastError?.contains("Settings") ?? false,
                      "Error should point the user at Settings: \(svc.lastError ?? "nil")")
    }

    func test_liveRemoteFailure_setsLastError() async {
        // The live/dictation path must surface a remote failure, not return a
        // silently-empty result indistinguishable from "no speech detected".
        let suite = UserDefaults(suiteName: "TranscriptionServiceTests.liveRemoteFail")!
        suite.removePersistentDomain(forName: "TranscriptionServiceTests.liveRemoteFail")
        let keychainKey = "TranscriptionServiceTests.liveRemoteFail.apiKey"
        defer { KeychainHelper.delete(key: keychainKey) }
        let remote = RemoteTranscriptionSettings(
            defaults: suite, apiKeyKeychainKey: keychainKey)
        remote.backend = .remote
        // Self-hosted endpoint → isConfigured without a key, so routing reaches
        // the (injected, always-throwing) remote engine.
        remote.endpoint = "http://localhost:8080/v1"
        let svc = TranscriptionService(
            store: store, modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServiceTests.liveRemoteFail.diar")!),
            remoteSettings: remote, engine: StubWhisperEngine(),
            remoteEngine: ThrowingRemoteEngine())

        XCTAssertNil(svc.lastError)
        let segs = await svc.transcribeOnceSegments(samples: [0.1, 0.2, 0.3], language: "he", audioCtx: nil)
        XCTAssertTrue(segs.isEmpty, "A remote failure yields no segments")
        XCTAssertNotNil(svc.lastError, "A live remote failure must surface, not silently empty the pane")
    }

    // MARK: - Single recording happy path

    func test_enqueue_single_recording_marks_running_then_completed() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Hello")
        let canned = [TranscriptSegment(start: 0, end: 0.5, text: "שלום")]
        await stub.setDefaultCanned(canned)

        XCTAssertNil(service.activeRecordingID)
        service.enqueue(fixture.recording)
        XCTAssertTrue(service.pendingIDs.contains(fixture.recording.id) ||
                      service.activeRecordingID == fixture.recording.id,
                      "Just-enqueued recording must be either active or pending")

        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.fullText, "שלום")
        XCTAssertEqual(stored.segments.count, 1)
        XCTAssertEqual(stored.modelName, WhisperModel.ivritLarge.displayName)
        XCTAssertNil(service.activeRecordingID)
        XCTAssertTrue(service.pendingIDs.isEmpty)
    }

    // MARK: - The bug we're fixing

    /// REGRESSION: Before the queue refactor, calling enqueue twice while the
    /// first transcription was still running would stomp on `activeRecordingID`
    /// and `progress`, making the UI think the OLD recording was being
    /// transcribed even after the NEW one started.
    func test_enqueueing_second_recording_during_first_does_not_drop_either() async throws {
        let a = try TestRecordingFixture.make(in: store, title: "A")
        let b = try TestRecordingFixture.make(in: store, title: "B")

        await stub.setDefaultDelay(0.25)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "from A")],
            [TranscriptSegment(start: 0, end: 1, text: "from B")]
        ])

        service.enqueue(a.recording)
        service.enqueue(b.recording)

        await service.waitForIdle()

        let storedA = try XCTUnwrap(store.recordings.first { $0.id == a.recording.id })
        let storedB = try XCTUnwrap(store.recordings.first { $0.id == b.recording.id })

        XCTAssertEqual(storedA.status, .completed)
        XCTAssertEqual(storedA.fullText, "from A")

        XCTAssertEqual(storedB.status, .completed)
        XCTAssertEqual(storedB.fullText, "from B")

        let maxConcurrent = await stub.maxConcurrentInFlight
        XCTAssertEqual(maxConcurrent, 1,
                       "The queue must serialize work; we never want two transcriptions live at once")
    }

    // MARK: - Strict FIFO ordering

    func test_three_recordings_process_in_FIFO_order() async throws {
        let a = try TestRecordingFixture.make(in: store, title: "Alpha")
        let b = try TestRecordingFixture.make(in: store, title: "Bravo")
        let c = try TestRecordingFixture.make(in: store, title: "Charlie")

        await stub.setDefaultDelay(0.05)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "alpha-text")],
            [TranscriptSegment(start: 0, end: 1, text: "bravo-text")],
            [TranscriptSegment(start: 0, end: 1, text: "charlie-text")]
        ])

        service.enqueue(a.recording)
        service.enqueue(b.recording)
        service.enqueue(c.recording)

        // While the worker is working we should see the right queue depth.
        XCTAssertEqual(service.pendingIDs.count + (service.activeRecordingID == nil ? 0 : 1), 3)

        await service.waitForIdle()

        let map = Dictionary(uniqueKeysWithValues: store.recordings.map { ($0.id, $0) })
        XCTAssertEqual(map[a.recording.id]?.fullText, "alpha-text")
        XCTAssertEqual(map[b.recording.id]?.fullText, "bravo-text")
        XCTAssertEqual(map[c.recording.id]?.fullText, "charlie-text")

        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 3)
    }

    // MARK: - Progress updates only the active recording

    func test_progress_updates_only_apply_to_active_recording() async throws {
        let a = try TestRecordingFixture.make(in: store, title: "First")
        let b = try TestRecordingFixture.make(in: store, title: "Second")

        await stub.setDefaultDelay(0.15)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "ok")],
            [TranscriptSegment(start: 0, end: 1, text: "ok")]
        ])

        service.enqueue(a.recording)
        service.enqueue(b.recording)

        // Sample progress while running. activeRecordingID and progress must
        // refer to the same job at every observation.
        var observations: [(UUID?, Double)] = []
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline,
              service.activeRecordingID != nil || !service.pendingIDs.isEmpty {
            observations.append((service.activeRecordingID, service.progress))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await service.waitForIdle()

        // Whenever progress was non-zero, activeRecordingID had to be non-nil.
        for (id, prog) in observations where prog > 0 {
            XCTAssertNotNil(id, "progress=\(prog) but no activeRecordingID")
        }
        // We must have seen both recordings serve as active at some point.
        let seen = Set(observations.compactMap(\.0))
        XCTAssertTrue(seen.contains(a.recording.id), "First recording never became active")
        XCTAssertTrue(seen.contains(b.recording.id), "Second recording never became active")
    }

    // MARK: - Idempotent enqueue

    func test_enqueue_is_idempotent_for_same_recording_id() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Once")
        await stub.setDefaultDelay(0.1)

        service.enqueue(fixture.recording)
        service.enqueue(fixture.recording)
        service.enqueue(fixture.recording)

        await service.waitForIdle()

        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1, "Duplicate enqueues should be ignored")
    }

    // MARK: - Failure path

    func test_engine_failure_marks_recording_as_failed_and_continues_queue() async throws {
        let a = try TestRecordingFixture.make(in: store, title: "Will fail")
        let b = try TestRecordingFixture.make(in: store, title: "Should still run")

        await stub.setNextError(NSError(domain: "TestEngine", code: 42,
                                        userInfo: [NSLocalizedDescriptionKey: "fake whisper crash"]))
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "second one fine")
        ])

        service.enqueue(a.recording)
        service.enqueue(b.recording)

        await service.waitForIdle()

        let storedA = try XCTUnwrap(store.recordings.first { $0.id == a.recording.id })
        let storedB = try XCTUnwrap(store.recordings.first { $0.id == b.recording.id })

        XCTAssertEqual(storedA.status, .failed)
        XCTAssertEqual(storedA.fullText, "")
        XCTAssertEqual(storedB.status, .completed)
        XCTAssertEqual(storedB.fullText, "second one fine")
        XCTAssertNotNil(service.lastError)
    }

    // MARK: - Empty transcript counts as failure

    func test_empty_transcript_is_marked_failed() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Silent")
        await stub.setDefaultCanned([])

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.fullText, "")
    }

    // MARK: - User-reported "every empty recording shows the same transcript"

    /// REGRESSION: When the second/third Voice Memo captures almost no audio
    /// (because of an `AVAudioEngine` restart bug), the auto-gain in
    /// WhisperEngine amplifies that ~60ms of mic noise to clipping levels and
    /// Whisper hallucinates a confident-looking Hebrew test phrase like
    /// "1, 2, 3, בדיקה, בדיקה, 4, 5" — the SAME phrase for every silent
    /// recording. From the user's POV it looks like the new recording is
    /// "stuck on the previous one's transcript".
    ///
    /// The transcription service must short-circuit on essentially-silent /
    /// extremely short audio so we never hand it to Whisper at all.
    func test_silent_or_too_short_audio_is_rejected_without_calling_whisper() async throws {
        let url = store.freshAudioURL(suggestedName: "Silent")
        try TestSupport.writeSineWav(at: url,
                                     durationSeconds: 0.06,
                                     amplitude: 0.0001)
        let recording = Recording(
            title: "Silent",
            duration: 0.06,
            source: .microphone,
            audioFileName: url.lastPathComponent,
            language: "he"
        )
        store.add(recording)

        // If the guard is missing, the stub will return this and the user will
        // see it as a "ghost transcript" on the empty recording — exactly the
        // bug being fixed.
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1,
                              text: "GHOST TRANSCRIPT THAT MUST NEVER APPEAR")
        ])

        service.enqueue(recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.fullText, "")
        XCTAssertTrue(stored.segments.isEmpty)

        let calls = await stub.transcribeCalls
        XCTAssertTrue(calls.isEmpty,
                      "Whisper must NOT be called on essentially-silent / extremely short audio")
    }

    /// Companion to the above: a normal audio file (>= the duration threshold,
    /// non-trivial peak) MUST go through Whisper as expected. We don't want to
    /// over-correct and start dropping legitimate quiet recordings.
    func test_quiet_but_audible_recording_still_reaches_whisper() async throws {
        let url = store.freshAudioURL(suggestedName: "Quiet but audible")
        try TestSupport.writeSineWav(at: url,
                                     durationSeconds: 1.0,
                                     amplitude: 0.05)
        let recording = Recording(
            title: "Quiet but audible",
            duration: 1.0,
            source: .microphone,
            audioFileName: url.lastPathComponent,
            language: "he"
        )
        store.add(recording)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "should be transcribed")
        ])

        service.enqueue(recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.fullText, "should be transcribed")
        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - Soft-deleted recordings are skipped

    func test_soft_deleted_recording_is_not_transcribed() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Trashed")
        store.softDelete(fixture.recording)

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let calls = await stub.transcribeCalls
        XCTAssertTrue(calls.isEmpty, "Should not run whisper on a deleted recording")
    }

    // MARK: - Model gating

    func test_no_model_installed_marks_recording_failed() async throws {
        try manager.delete(.ivritLarge)
        XCTAssertFalse(manager.isInstalled(.ivritLarge))

        let fixture = try TestRecordingFixture.make(in: store, title: "Skipped")
        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .failed)

        let calls = await stub.transcribeCalls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - transcribeOnce (dictation path)

    func test_transcribe_once_returns_concatenated_segment_text() async {
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 0.5, text: "שלום "),
            TranscriptSegment(start: 0.5, end: 1.0, text: "עולם")
        ])

        let samples = [Float](repeating: 0.1, count: 16_000)
        let text = await service.transcribeOnce(samples: samples, language: "he")

        XCTAssertEqual(text, "שלום עולם")
    }

    func test_transcribe_once_returns_empty_when_engine_throws() async {
        await stub.setNextError(NSError(domain: "TestEngine", code: 7))

        let samples = [Float](repeating: 0.1, count: 16_000)
        let text = await service.transcribeOnce(samples: samples, language: "he")
        XCTAssertEqual(text, "")
    }

    // MARK: - Cancellation

    /// Cancelling a recording while it's still pending in the queue should
    /// short-circuit `process()` so whisper is never called. This is the
    /// path users hit most often — they cancel before the model even loads.
    func test_cancel_before_active_skips_whisper_entirely() async throws {
        let blocker = try TestRecordingFixture.make(in: store, title: "Blocker")
        let target = try TestRecordingFixture.make(in: store, title: "Target")

        // Make the first job slow so the second sits in the queue while we
        // cancel it.
        await stub.setDefaultDelay(0.4)

        service.enqueue(blocker.recording)
        service.enqueue(target.recording)

        // Wait for the worker to actually pop the blocker as the active job
        // before we cancel — that's the realistic scenario for users (one
        // recording is being transcribed, a new one is queued behind it).
        let activeDeadline = Date().addingTimeInterval(2)
        while service.activeRecordingID != blocker.recording.id && Date() < activeDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.pendingIDs, [target.recording.id])

        service.cancel(recordingID: target.recording.id)
        XCTAssertTrue(service.pendingIDs.isEmpty,
                      "Cancel must drop the recording from pendingIDs immediately")

        await service.waitForIdle()

        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1, "Only the blocker should have hit whisper")
    }

    /// Cancelling while the recording is the active job should trip the
    /// abort_callback the stub polls. The stub throws `CancellationError`
    /// when it sees the flag flip, exactly mirroring whisper.cpp's behaviour
    /// when `abort_callback` returns true mid-`whisper_full`.
    func test_cancel_during_active_aborts_via_callback() async throws {
        let target = try TestRecordingFixture.make(in: store, title: "Mid-run")
        await stub.setDefaultDelay(0.4)

        service.enqueue(target.recording)

        // Wait for the worker to actually pick the job up.
        let deadline = Date().addingTimeInterval(2)
        while service.activeRecordingID != target.recording.id && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.activeRecordingID, target.recording.id)

        service.cancel(recordingID: target.recording.id)
        await service.waitForIdle()

        // The recording must NOT be marked as `.failed` — that's a user-
        // initiated cancel, not an engine error. The coordinator will be
        // along to delete it shortly.
        let stored = try XCTUnwrap(store.recordings.first { $0.id == target.recording.id })
        XCTAssertNotEqual(stored.status, .failed,
                          "User-cancelled recordings must not surface as engine failures")
    }

    // MARK: - Re-transcribe with the other language

    /// Drives the right-click "Re-transcribe in [other language]" path: the
    /// caller flips `recording.language` from `"he"` to `"en"` and re-enqueues.
    /// The service must pick that up and load the OpenAI model on the second
    /// pass instead of the ivrit.ai one used on the first.
    func test_changing_recording_language_routes_to_other_model_on_reenqueue() async throws {
        try TestSupport.installFakeModel(into: manager, model: .openaiTurbo)

        let fixture = try TestRecordingFixture.make(in: store,
                                                    title: "Was Hebrew",
                                                    language: "he")
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "first pass")],
            [TranscriptSegment(start: 0, end: 1, text: "second pass")]
        ])

        service.enqueue(fixture.recording)
        await service.waitForIdle()
        let firstLoad = await stub.loadedModel
        XCTAssertEqual(firstLoad?.lastPathComponent,
                       manager.url(for: .ivritLarge).lastPathComponent,
                       "First pass should hit the Hebrew model")

        var swapped = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        swapped.language = "en"
        swapped.status = .pending
        store.update(swapped)
        service.enqueue(swapped)
        await service.waitForIdle()

        let secondLoad = await stub.loadedModel
        XCTAssertEqual(secondLoad?.lastPathComponent,
                       manager.url(for: .openaiTurbo).lastPathComponent,
                       "Second pass should hit the English model after the language swap")

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.fullText, "second pass")
        XCTAssertEqual(stored.language, "en")
        XCTAssertEqual(stored.status, .completed)
    }

    // MARK: - Speaker label normalization

    func test_normalizeSpeakerLabels_closes_gaps_from_diarizer_clustering() {
        // Pyannote occasionally emits non-contiguous speaker ids
        // (SPEAKER_00 and SPEAKER_02 with no SPEAKER_01) when its
        // clustering pass merges an intermediate cluster. The UI
        // would otherwise show "Speaker A, Speaker C" with no B.
        let segments: [TranscriptSegment] = [
            .init(start: 0, end: 1, text: "hi", speaker: "SPEAKER_00"),
            .init(start: 1, end: 2, text: "yo", speaker: "SPEAKER_02"),
            .init(start: 2, end: 3, text: "ya", speaker: "SPEAKER_00"),
            .init(start: 3, end: 4, text: "bye", speaker: "SPEAKER_02"),
        ]
        let normalized = TranscriptionService.normalizeSpeakerLabels(in: segments)
        XCTAssertEqual(normalized.map(\.speaker),
                       ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00", "SPEAKER_01"])
    }

    func test_normalizeSpeakerLabels_uses_first_appearance_order() {
        // The user who SPEAKS FIRST always ends up as SPEAKER_00,
        // regardless of what id pyannote happened to assign.
        let segments: [TranscriptSegment] = [
            .init(start: 0, end: 1, text: "first speaker", speaker: "SPEAKER_05"),
            .init(start: 1, end: 2, text: "second speaker", speaker: "SPEAKER_01"),
            .init(start: 2, end: 3, text: "third speaker", speaker: "SPEAKER_03"),
            .init(start: 3, end: 4, text: "first again", speaker: "SPEAKER_05"),
        ]
        let normalized = TranscriptionService.normalizeSpeakerLabels(in: segments)
        XCTAssertEqual(normalized.map(\.speaker),
                       ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02", "SPEAKER_00"])
    }

    func test_normalizeSpeakerLabels_passes_through_segments_without_labels() {
        // Mixed: some segments have speakers, some don't (e.g.
        // background noise the diarizer couldn't attribute). The
        // unlabeled segments stay unlabeled; only the labeled ones
        // get renumbered.
        let segments: [TranscriptSegment] = [
            .init(start: 0, end: 1, text: "a", speaker: "SPEAKER_03"),
            .init(start: 1, end: 2, text: "b", speaker: nil),
            .init(start: 2, end: 3, text: "c", speaker: "SPEAKER_07"),
        ]
        let normalized = TranscriptionService.normalizeSpeakerLabels(in: segments)
        XCTAssertEqual(normalized[0].speaker, "SPEAKER_00")
        XCTAssertNil(normalized[1].speaker)
        XCTAssertEqual(normalized[2].speaker, "SPEAKER_01")
    }
}

/// Returns 401 for any request — lets the record-start probe reach `.failed`
/// without a real server. (Distinct from `RemoteTranscriptionTests`' copy so
/// each test file is self-contained.)
private final class Probe401URLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Incorrect API key provided: test-key-123"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A remote engine that always throws an HTTP 401 — stands in for a
/// misconfigured remote backend so the live-path error-surfacing can be tested
/// without a network round-trip.
private actor ThrowingRemoteEngine: RemoteTranscribing {
    func configure(_ config: RemoteTranscriptionConfig) async {}
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {}
    func shutdown() async {}
    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        throw RemoteWhisperEngine.RemoteError.http(
            status: 401,
            body: #"{"error":{"message":"Incorrect API key provided: test-key-123"}}"#)
    }
}
