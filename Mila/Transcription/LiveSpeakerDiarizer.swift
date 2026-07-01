import Foundation
import Combine
import OSLog

private let diarLog = MilaLog(category: "LiveSpeakerDiarizer")

/// Streams speaker labels during a live recording by sending 5 s WAV chunks
/// to a long-running Python daemon that computes a pyannote/wespeaker
/// embedding per chunk. Swift maintains a pool of speaker centroids and
/// assigns stable `SPEAKER_00`, `SPEAKER_01`, … labels via cosine similarity.
///
/// The daemon model:
///   * loads the bundled pyannote Pipeline once at startup (~3–5 s cold
///     start — far cheaper than spawning a fresh subprocess every tick),
///   * extracts the embedding `Inference` object (`pipeline._embedding`)
///     and skips the heavy segmentation/clustering pass,
///   * reads commands as one JSON line per request on stdin
///     (`{"cmd":"embed","wav":"/tmp/…"}`), writes one JSON line per
///     response on stdout (`{"embedding":[…256 floats…]}` or
///     `{"error":"…"}`).
///
/// If the daemon fails to start (no Python, no models, dependency missing)
/// we publish `lastError` and `intervals` stays empty — the live UI just
/// shows unlabeled text. This is the documented `isConfigured` invariant
/// from `.claude/rules/feature-gates.md`: optional features must degrade
/// to a no-op rather than crashing the recording.
@MainActor
final class LiveSpeakerDiarizer: ObservableObject {
    /// Intervals labeled by this diarizer over the lifetime of the current
    /// recording. Each maps a (start, end) absolute-seconds window to one
    /// of the stable speaker IDs (`SPEAKER_00`, …).
    @Published private(set) var intervals: [(start: Double, end: Double, speaker: String)] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isReady: Bool = false

    /// Cosine threshold above which an incoming embedding is considered
    /// the same speaker as an existing pool entry. 0.55 fits wespeaker's
    /// short-utterance embeddings — VAD emits 1-5s clips and same-
    /// speaker cosine similarity at that length typically lands in
    /// 0.5-0.7 (not 0.75-0.95 which is the long-clip range). Anything
    /// tighter splits the same person across many SPEAKER_NN IDs.
    /// Tunable in Settings.
    var similarityThreshold: Double = 0.55

    private var pool: [SpeakerProfile] = []
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    /// Pending one-shot response continuations. Each `embed` command
    /// resolves the next one — daemon protocol is strictly request /
    /// response so first-in-first-out.
    private var pending: [CheckedContinuation<EmbedResponse, Never>] = []
    private var stderrTask: Task<Void, Never>?
    /// Tail of the chained background-diarize tasks. Each `submit(...)`
    /// chains a new Task that awaits the previous one before running
    /// `process(...)`, so the chain enforces FIFO over the daemon and
    /// `awaitPending()` can join the final tail at end-of-recording.
    private var processQueue: Task<Void, Never>?

    struct SpeakerProfile {
        let id: String
        var centroid: [Float]
        var sampleCount: Int
    }

    private struct EmbedResponse: Decodable {
        let embedding: [Float]?
        let error: String?
    }

    /// Boot the Python daemon. No-op if a daemon is already running, or
    /// if diarization is disabled / not configured. Throws nothing — any
    /// failure becomes a `lastError` so callers don't have to wrap try/
    /// catch around every recording start.
    func start(diarization: DiarizationSettings) async {
        guard process == nil else {
            diarLog.log("start skipped — daemon already running")
            return
        }
        guard diarization.isConfigured else {
            lastError = "Diarization is not configured"
            diarLog.log("NOT starting — isConfigured=false (isEnabled=\(diarization.isEnabled, privacy: .public) hasBundledRuntime=\(diarization.hasBundledRuntime, privacy: .public) bootstrap.isReady=\(diarization.bootstrap.isReady, privacy: .public))")
            return
        }
        guard let modelsPath = Bundle.main.path(forResource: "DiarizationModels", ofType: nil) else {
            lastError = "Bundled diarization models not found in app"
            diarLog.log("NOT starting — DiarizationModels not in app bundle")
            return
        }
        let pythonPath = SpeakerDiarizer.resolvePython(userConfigured: diarization.pythonPath)
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            lastError = "Python not found at \(pythonPath)"
            diarLog.log("NOT starting — python not at \(pythonPath, privacy: .public)")
            return
        }
        diarLog.log("starting daemon python=\(pythonPath, privacy: .public)")

        let script = Self.daemonScript
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-u", "-c", script, modelsPath]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in SpeakerDiarizer.pythonEnvironment() {
            env[k] = v
        }
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            lastError = "Could not launch diarization daemon: \(error.localizedDescription)"
            return
        }

        self.process = process
        self.stdinPipe = stdin
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading
        startStdoutReader()
        startStderrReader()

        // Wait for the ready handshake before declaring success. The
        // daemon emits `{"ready":true}` on stdout once the pipeline and
        // embedding inference are loaded.
        let ready = await waitForReady(timeoutSeconds: 30)
        isReady = ready
        diarLog.log("daemon ready=\(ready, privacy: .public)")
        if !ready {
            lastError = lastError ?? "Diarization daemon did not become ready"
        }
    }

    /// Shut down the daemon. Idempotent. Called when a recording stops.
    func stop() {
        if let stdin = stdinPipe {
            let cmd = #"{"cmd":"shutdown"}\#n"#
            try? stdin.fileHandleForWriting.write(contentsOf: Data(cmd.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutHandle = nil
        stderrHandle = nil
        stdoutBuffer.removeAll()
        for cont in pending { cont.resume(returning: .init(embedding: nil, error: "stopped")) }
        pending.removeAll()
        stderrTask?.cancel()
        stderrTask = nil
        isReady = false
    }

    /// Reset the speaker pool. New recording = fresh pool — we never carry
    /// embeddings across recordings (a participant who joined last meeting
    /// might be the same person, but assigning the same SPEAKER_00 across
    /// unrelated calls is more confusing than starting fresh).
    func reset() {
        pool.removeAll()
        intervals.removeAll()
    }

    /// Fire-and-track variant of `process(...)`. Chains the call onto
    /// `processQueue` so the FIFO order matches the daemon's, and
    /// `awaitPending()` can join the tail. Use this from the live-
    /// recording pipeline; use `process(...)` directly only for tests.
    func submit(samples: [Float], startSeconds: Double, endSeconds: Double, sampleRate: Double = 16_000) {
        let prev = processQueue
        processQueue = Task { @MainActor [weak self] in
            await prev?.value
            await self?.process(samples: samples,
                                startSeconds: startSeconds,
                                endSeconds: endSeconds,
                                sampleRate: sampleRate)
        }
    }

    /// Wait for every queued `submit(...)` call to finish. Used at
    /// end-of-recording so the final utterance's interval lands in
    /// `intervals` before the saved transcript is read.
    func awaitPending() async {
        await processQueue?.value
    }

    /// Diarize one chunk of samples covering [`startSeconds`, `endSeconds`]
    /// of the recording's timeline. Writes the slice to a temp WAV and
    /// sends the path to the daemon. Returns nothing — appends to
    /// `intervals` for the live transcriber to pick up via
    /// `applySpeakerLabels(_:)`.
    func process(samples: [Float], startSeconds: Double, endSeconds: Double, sampleRate: Double = 16_000) async {
        diarLog.log("process called: samples=\(samples.count, privacy: .public) start=\(startSeconds, privacy: .public) end=\(endSeconds, privacy: .public) isReady=\(self.isReady, privacy: .public)")
        guard isReady, !samples.isEmpty else {
            diarLog.log("process SKIPPED isReady=\(self.isReady, privacy: .public) samplesEmpty=\(samples.isEmpty, privacy: .public)")
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-live-diar-\(UUID().uuidString).wav")
        do {
            try writeMono16WAV(samples: samples, sampleRate: sampleRate, to: tempURL)
        } catch {
            lastError = "Could not write live diar chunk: \(error.localizedDescription)"
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let payload: [String: Any] = ["cmd": "embed", "wav": tempURL.path]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        let sendStart = Date()
        diarLog.log("sending embed cmd to daemon, wav=\(tempURL.path, privacy: .public)")
        let response = await sendCommand("\(line)\n")
        let elapsed = Date().timeIntervalSince(sendStart)
        diarLog.log("daemon response after \(elapsed, privacy: .public)s: embedding=\(response.embedding?.count ?? 0, privacy: .public) error=\(response.error ?? "(none)", privacy: .public)")
        guard let embedding = response.embedding, !embedding.isEmpty else {
            if let err = response.error { lastError = "Diar daemon: \(err)" }
            return
        }
        let speakerID = assign(embedding: embedding, utteranceDuration: endSeconds - startSeconds)
        intervals.append((start: startSeconds, end: endSeconds, speaker: speakerID))
        diarLog.log("interval added: \(startSeconds, privacy: .public)..\(endSeconds, privacy: .public) → \(speakerID, privacy: .public) (poolSize=\(self.pool.count, privacy: .public) totalIntervals=\(self.intervals.count, privacy: .public))")
    }

    /// Match a new embedding against the pool by cosine similarity, using a
    /// two-tier (hysteresis) policy to curb over-segmentation:
    ///
    ///   • `sim ≥ similarityThreshold` → confident match; fold the
    ///     embedding into that speaker's centroid (running mean).
    ///   • `createThreshold ≤ sim < similarityThreshold`, OR the utterance
    ///     is too short to trust as a new voice → attach to the closest
    ///     existing speaker WITHOUT updating its centroid (a marginal match
    ///     shouldn't be allowed to drift the representation).
    ///   • `sim < createThreshold` (or the pool is empty) → mint a new
    ///     speaker.
    ///
    /// Why: wespeaker cosine sim for the SAME speaker on 1-5s VAD chunks
    /// routinely dips to ~0.45-0.55, so a single hard threshold minted a
    /// fresh `SPEAKER_NN` for a big fraction of one person's sentences
    /// (observed: 7+ speakers for a single-narrator video). Requiring a
    /// clearly-dissimilar embedding — or a long-enough utterance — before
    /// creating a speaker keeps the live pool from exploding. The offline
    /// pass at stop still does the authoritative global clustering.
    func assign(embedding: [Float], utteranceDuration: Double = 2.0) -> String {
        var best: (idx: Int, sim: Double)?
        for (idx, profile) in pool.enumerated() {
            let sim = cosineSimilarity(embedding, profile.centroid)
            if best == nil || sim > best!.sim {
                best = (idx, sim)
            }
        }
        let bestSim = best?.sim ?? -1.0
        let bestId = best.map { pool[$0.idx].id } ?? "(none)"
        // Floor for minting a new speaker — kept a notch below the match
        // threshold so borderline utterances attach rather than fork.
        // Clamped so a low user-set threshold can't drive it negative.
        let createThreshold = max(0.40, similarityThreshold - 0.15)
        // Short chunks give noisy embeddings; don't let them mint a new
        // speaker when we already have a pool to attach to.
        let longEnoughForNewSpeaker = utteranceDuration >= 1.0
        diarLog.log("assign: poolSize=\(self.pool.count, privacy: .public) bestMatch=\(bestId, privacy: .public) bestSim=\(bestSim, privacy: .public) threshold=\(self.similarityThreshold, privacy: .public) createThreshold=\(createThreshold, privacy: .public) dur=\(utteranceDuration, privacy: .public)")
        if let chosen = best, chosen.sim >= similarityThreshold {
            // Confident match → fold into the centroid (running mean).
            let n = pool[chosen.idx].sampleCount
            var centroid = pool[chosen.idx].centroid
            for i in 0..<centroid.count {
                centroid[i] = (centroid[i] * Float(n) + embedding[i]) / Float(n + 1)
            }
            pool[chosen.idx].centroid = centroid
            pool[chosen.idx].sampleCount = n + 1
            return pool[chosen.idx].id
        }
        // Borderline, or too short to trust as a new voice → attach to the
        // closest existing speaker (leave its centroid untouched).
        if let chosen = best, chosen.sim >= createThreshold || !longEnoughForNewSpeaker {
            return pool[chosen.idx].id
        }
        let nextID = String(format: "SPEAKER_%02d", pool.count)
        pool.append(SpeakerProfile(id: nextID, centroid: embedding, sampleCount: 1))
        return nextID
    }

    // MARK: - Daemon I/O

    private func sendCommand(_ line: String) async -> EmbedResponse {
        guard let stdin = stdinPipe else {
            return .init(embedding: nil, error: "no daemon")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<EmbedResponse, Never>) in
            pending.append(cont)
            do {
                try stdin.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            } catch {
                // The write failed (daemon likely died). The continuation
                // we just queued won't get a response from the daemon, so
                // resume it here and pop it. It must be the most recently
                // added entry since the queue is strictly FIFO.
                _ = pending.popLast()
                cont.resume(returning: .init(embedding: nil, error: error.localizedDescription))
            }
        }
    }

    private func waitForReady(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            // The stdout reader fills `stdoutBuffer` and dispatches lines
            // to pending continuations. If isReady is set elsewhere, exit.
            if isReady { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return isReady
    }

    private func startStdoutReader() {
        guard let handle = stdoutHandle else { return }
        // Set up a readability handler that appends data, splits on newlines,
        // and dispatches each complete line. Closures touching `self` hop
        // back to the main actor before mutating state.
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                // EOF — daemon exited.
                Task { @MainActor [weak self] in
                    self?.failPending(error: "daemon exited")
                }
                fh.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.consumeStdout(data)
            }
        }
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIdx = stdoutBuffer.firstIndex(of: 0x0a) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIdx)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIdx)
            handleLine(lineData)
        }
    }

    private func handleLine(_ data: Data) {
        struct ReadyMsg: Decodable { let ready: Bool? }
        if let ready = try? JSONDecoder().decode(ReadyMsg.self, from: data), ready.ready == true {
            isReady = true
            return
        }
        guard !pending.isEmpty else { return }
        let cont = pending.removeFirst()
        if let resp = try? JSONDecoder().decode(EmbedResponse.self, from: data) {
            cont.resume(returning: resp)
        } else {
            cont.resume(returning: .init(embedding: nil, error: "could not parse daemon response"))
        }
    }

    private func failPending(error: String) {
        for cont in pending {
            cont.resume(returning: .init(embedding: nil, error: error))
        }
        pending.removeAll()
        isReady = false
    }

    private func startStderrReader() {
        guard let handle = stderrHandle else { return }
        stderrTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    // Route stderr through os.Logger so we can read
                    // Python progress + tracebacks via `log show`.
                    // The daemon's `print(..., file=sys.stderr,
                    // flush=True)` lines land here, including the
                    // "live-diar: embed error" traceback we'd
                    // otherwise miss on silent failures.
                    let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stripped.isEmpty {
                        diarLog.log("daemon stderr: \(stripped, privacy: .public)")
                    }
                }
                _ = self  // keep reference alive
            }
        }
    }

    // MARK: - WAV writing

    private func writeMono16WAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        // Minimal 32-bit float WAV writer — matches the format RecordingSession
        // uses so the daemon's soundfile.read returns the same float32 floats
        // Mila already has in memory.
        let bitsPerSample: UInt16 = 32
        let channels: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let dataBytes = UInt32(samples.count * 4)
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(36 + dataBytes).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)              // fmt chunk size
        data.append(UInt16(3).littleEndianData)               // 3 = IEEE float
        data.append(channels.littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(byteRate.littleEndianData)
        data.append(blockAlign.littleEndianData)
        data.append(bitsPerSample.littleEndianData)
        data.append("data".data(using: .ascii)!)
        data.append(dataBytes.littleEndianData)
        let byteCount = samples.count * MemoryLayout<Float>.size
        samples.withUnsafeBytes { rawBuf in
            if let base = rawBuf.baseAddress {
                data.append(base.assumingMemoryBound(to: UInt8.self), count: byteCount)
            }
        }
        try data.write(to: url)
    }

    // MARK: - Daemon script

    private static let daemonScript = """
import json, sys, os, types, traceback
import numpy as np

# Same speechbrain lazy-module patch as the batch diarizer — pyannote 3.x
# triggers speechbrain stack inspection which tries to import optional
# packages and crashes if they're missing.
try:
    import speechbrain.utils.importutils as _sbiu
    _orig_ensure = _sbiu.LazyModule.ensure_module
    def _safe_ensure(self, *a, **kw):
        try:
            return _orig_ensure(self, *a, **kw)
        except ImportError:
            self.lazy_module = types.ModuleType(self.target)
            return self.lazy_module
    _sbiu.LazyModule.ensure_module = _safe_ensure
except Exception:
    pass

import torch
_orig_torch_load = torch.load
def _patched_torch_load(*args, **kwargs):
    kwargs["weights_only"] = False
    return _orig_torch_load(*args, **kwargs)
torch.load = _patched_torch_load

import soundfile as sf
from pyannote.audio import Pipeline

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\\n")
    sys.stdout.flush()

def main():
    models_dir = sys.argv[1]
    config_path = os.path.join(models_dir, "config.yaml")
    import tempfile
    with open(config_path) as f:
        config_text = f.read().replace("__MODELS_DIR__", models_dir)
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False)
    tmp.write(config_text); tmp.close()

    try:
        print("live-diar: loading pyannote pipeline", file=sys.stderr, flush=True)
        pipeline = Pipeline.from_pretrained(tmp.name)
        if torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
            print("live-diar: using MPS", file=sys.stderr, flush=True)
        # `_embedding` is the Inference object pyannote uses internally
        # for speaker embeddings. Public API doesn't expose it directly
        # but the attribute is stable across 3.x releases.
        embedder = getattr(pipeline, "_embedding", None)
        if embedder is None:
            emit({"error": "pipeline._embedding not available"})
            return
    finally:
        os.unlink(tmp.name)

    emit({"ready": True})
    print("live-diar: ready", file=sys.stderr, flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except Exception as e:
            emit({"error": "bad json: %s" % e})
            continue
        op = cmd.get("cmd")
        if op == "shutdown":
            break
        if op != "embed":
            emit({"error": "unknown cmd %s" % op})
            continue
        wav_path = cmd.get("wav", "")
        if not wav_path or not os.path.exists(wav_path):
            emit({"error": "wav not found"})
            continue
        try:
            samples, sr = sf.read(wav_path, dtype="float32")
            if samples.ndim > 1:
                samples = samples.mean(axis=1)
            # pyannote 3.x's `pipeline._embedding` is a
            # `PretrainedSpeakerEmbedding`, NOT an `Inference` wrapper —
            # so it takes a torch.Tensor of shape
            #   (batch_size, num_channels, num_samples)
            # directly. Passing a `{"waveform": ..., "sample_rate": ...}`
            # dict (the file-input shape for `Inference`) made pyannote
            # try `.to(device)` on the dict and crash with
            # "'dict' object has no attribute 'to'" — silently swallowing
            # every embed request.
            wave = torch.from_numpy(samples).unsqueeze(0).unsqueeze(0)
            emb = embedder(wave)
            arr = emb.detach().cpu().numpy().flatten() if hasattr(emb, "detach") else np.array(emb).flatten()
            emit({"embedding": arr.tolist()})
        except Exception as e:
            tb = traceback.format_exc()
            print("live-diar: embed error %s\\n%s" % (e, tb), file=sys.stderr, flush=True)
            emit({"error": str(e)})

main()
"""
}

/// Cosine similarity between two equal-length vectors. Returns 0 for
/// zero-length / mismatched inputs so the caller still gets a Double back
/// without having to guard.
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Double = 0, normA: Double = 0, normB: Double = 0
    for i in 0..<a.count {
        dot += Double(a[i]) * Double(b[i])
        normA += Double(a[i]) * Double(a[i])
        normB += Double(b[i]) * Double(b[i])
    }
    let denom = (normA.squareRoot() * normB.squareRoot())
    return denom == 0 ? 0 : dot / denom
}

private extension UInt16 {
    var littleEndianData: Data {
        withUnsafeBytes(of: self.littleEndian) { Data($0) }
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        withUnsafeBytes(of: self.littleEndian) { Data($0) }
    }
}
