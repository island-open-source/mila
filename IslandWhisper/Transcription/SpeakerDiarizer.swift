import Foundation

struct SpeakerTurn: Codable {
    let start: Double
    let end: Double
    let speaker: String
}

enum SpeakerDiarizer {

    private static var bundledModelsPath: String? {
        Bundle.main.path(forResource: "DiarizationModels", ofType: nil)
    }

    enum Error: Swift.Error, LocalizedError {
        case pythonNotFound(String)
        case diarizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound(let path):
                return "Python not found at \(path). Install Python 3 with pyannote.audio."
            case .diarizationFailed(let msg):
                return "Speaker diarization failed: \(msg)"
            }
        }
    }

    private struct PythonResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private static func runPython(
        path: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> PythonResult {
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: path) else {
                throw Error.pythonNotFound(path)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            if let extra = environment { env.merge(extra) { _, new in new } }
            process.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            return PythonResult(
                stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
                stderr: stderr.fileHandleForReading.readDataToEndOfFile(),
                exitCode: process.terminationStatus
            )
        }.value
    }

    // MARK: - Public API

    static func installDependencies(pythonPath: String) async throws -> String {
        let result = try await runPython(
            path: pythonPath,
            arguments: ["-m", "pip", "install", "--upgrade", "pyannote.audio", "torch", "huggingface_hub<1.0"]
        )
        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        guard result.exitCode == 0 else {
            let errOutput = String(data: result.stderr, encoding: .utf8) ?? ""
            throw Error.diarizationFailed(errOutput.isEmpty ? output : errOutput)
        }
        return output
    }

    static func diarize(wavURL: URL, pythonPath: String) async throws -> [SpeakerTurn] {
        guard let modelsPath = bundledModelsPath else {
            throw Error.diarizationFailed("Bundled diarization models not found in app")
        }

        let script = """
        import json, sys, os, types, tempfile

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

        from pyannote.audio import Pipeline

        wav_path = sys.argv[1]
        models_dir = sys.argv[2]

        config_path = os.path.join(models_dir, "config.yaml")
        with open(config_path) as f:
            config_text = f.read().replace("__MODELS_DIR__", models_dir)

        tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False)
        tmp.write(config_text)
        tmp.close()

        try:
            print(f"diarize: loading pipeline from {models_dir}", file=sys.stderr)
            pipeline = Pipeline.from_pretrained(tmp.name)
            if torch.backends.mps.is_available():
                pipeline.to(torch.device("mps"))
                print(f"diarize: using MPS", file=sys.stderr)

            print(f"diarize: running on {wav_path}", file=sys.stderr)
            diar = pipeline(wav_path)
            annotation = getattr(diar, "speaker_diarization", diar)

            turns = []
            for turn, _, speaker in annotation.itertracks(yield_label=True):
                turns.append({
                    "start": round(turn.start, 3),
                    "end": round(turn.end, 3),
                    "speaker": speaker,
                })

            print(f"diarize: found {len(set(t['speaker'] for t in turns))} speakers, {len(turns)} turns", file=sys.stderr)
            json.dump(turns, sys.stdout)
        finally:
            os.unlink(tmp.name)
        """

        let result = try await runPython(
            path: pythonPath,
            arguments: ["-c", script, wavURL.path, modelsPath],
            environment: [:]
        )
        guard result.exitCode == 0 else {
            let errMsg = String(data: result.stderr, encoding: .utf8) ?? "exit code \(result.exitCode)"
            throw Error.diarizationFailed(errMsg)
        }
        return try JSONDecoder().decode([SpeakerTurn].self, from: result.stdout)
    }

    struct VerifyResult: Codable {
        let pyannoteInstalled: Bool
        let torchInstalled: Bool

        var allGood: Bool {
            pyannoteInstalled && torchInstalled
        }
    }

    static func verifySetup(pythonPath: String) async throws -> VerifyResult {
        let script = """
        import json, sys

        result = {
            "pyannoteInstalled": False,
            "torchInstalled": False,
        }

        try:
            import pyannote.audio
            result["pyannoteInstalled"] = True
        except ImportError:
            pass

        try:
            import torch
            result["torchInstalled"] = True
        except ImportError:
            pass

        json.dump(result, sys.stdout)
        """

        let result = try await runPython(
            path: pythonPath,
            arguments: ["-c", script]
        )
        guard !result.stdout.isEmpty else {
            let errMsg = String(data: result.stderr, encoding: .utf8) ?? "no output"
            throw Error.diarizationFailed(errMsg)
        }
        return try JSONDecoder().decode(VerifyResult.self, from: result.stdout)
    }

    static func assignSpeaker(segmentStart: Double, segmentEnd: Double, turns: [SpeakerTurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        let mid = (segmentStart + segmentEnd) / 2.0
        var best: String?
        var bestOverlap: Double = 0.0
        for turn in turns {
            let overlap = max(0.0, min(segmentEnd, turn.end) - max(segmentStart, turn.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = turn.speaker
            }
            if best == nil && turn.start <= mid && mid <= turn.end {
                best = turn.speaker
            }
        }
        return best
    }
}
