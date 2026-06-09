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

    /// Effective Python the subprocesses should launch. Bundle path wins if
    /// it exists (built via `make bundle-diarization` and bundled in
    /// Resources/PythonRuntime/); otherwise we fall back to whatever path
    /// the user has configured in DiarizationSettings (typically
    /// /usr/bin/python3). The bundle path is preferred because it lets the
    /// app run on machines without a working system pyannote install.
    static func resolvePython(userConfigured: String) -> String {
        DiarizationBootstrap.bundledPythonPath ?? userConfigured
    }

    /// Environment additions to make bundled site-packages visible.
    /// Returns an empty dict when no bundle is present, so behaviour for
    /// users on the legacy system-python flow is unchanged.
    static func pythonEnvironment() -> [String: String] {
        let path = DiarizationBootstrap.combinedPythonPath
        return path.isEmpty ? [:] : ["PYTHONPATH": path]
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

            // Drain both pipes in detached tasks to avoid deadlock.
            // macOS pipe buffers are ~64 KB — if the subprocess
            // fills stderr before we read it, it blocks on write()
            // while we block on waitUntilExit().
            let stdoutRead = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
            let stderrRead = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }

            process.waitUntilExit()

            return PythonResult(
                stdout: await stdoutRead.value,
                stderr: await stderrRead.value,
                exitCode: process.terminationStatus
            )
        }.value
    }

    // MARK: - Public API

    static func installDependencies(pythonPath: String) async throws -> String {
        // `soundfile` is required as an audio backend — pyannote.audio
        // crashes at import time with IndexError if torchaudio finds no
        // backend, and `soundfile` is the most reliable one on macOS.
        let result = try await runPython(
            path: pythonPath,
            arguments: ["-m", "pip", "install", "--upgrade",
                        "pyannote.audio", "torch", "soundfile", "huggingface_hub<1.0"]
        )
        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        guard result.exitCode == 0 else {
            let errOutput = String(data: result.stderr, encoding: .utf8) ?? ""
            throw Error.diarizationFailed(errOutput.isEmpty ? output : errOutput)
        }
        return output
    }

    /// Python module name → PyPI package name overrides. Most pyannote
    /// deps name themselves the same on PyPI as in import statements,
    /// but a few classic mismatches need translation: pip would fail
    /// otherwise ("Could not find a version that satisfies the
    /// requirement PIL"). Extend this list as new mismatches surface.
    private static let moduleToPackage: [String: String] = [
        "PIL": "Pillow",
        "sklearn": "scikit-learn",
        "yaml": "PyYAML",
        "cv2": "opencv-python-headless",
        "bs4": "beautifulsoup4",
    ]

    /// Targeted remediation when the bundled site-packages is missing a
    /// transitive pyannote dep (e.g. `torch_audiomentations` was excluded
    /// by an over-greedy filter in a prior bundle build). Installs the
    /// named module into the user-writable site-packages so the next
    /// `import pyannote.audio` succeeds.
    @discardableResult
    static func installMissingModule(pythonPath: String,
                                     userSitePackages: String,
                                     module: String) async throws -> String {
        let packageName = moduleToPackage[module] ?? module
        let result = try await runPython(
            path: pythonPath,
            arguments: ["-m", "pip", "install",
                        "--target", userSitePackages,
                        "--no-deps", "--only-binary=:all:",
                        packageName]
        )
        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        guard result.exitCode == 0 else {
            let errOutput = String(data: result.stderr, encoding: .utf8) ?? ""
            throw Error.diarizationFailed(errOutput.isEmpty ? output : errOutput)
        }
        return output
    }

    /// Targeted remediation for `code == "missing_audio_backend"`. We don't
    /// want a generic "install all dependencies" run to fix one missing
    /// wheel — that'd risk upgrading torch/pyannote unexpectedly. This just
    /// adds `soundfile` (the pyannote-recommended backend on macOS) and
    /// leaves everything else alone.
    ///
    /// `--force-reinstall --no-cache-dir` is intentional, not paranoid: the
    /// real-world failure mode here is *not* "soundfile missing", it's
    /// "soundfile installed but its `_cffi_backend.so` is for the wrong
    /// architecture" (typically a leftover x86_64 wheel on an arm64 Mac).
    /// A plain install in that state is a no-op — pip happily reports
    /// "Requirement already satisfied" — so the next health check would
    /// still fail. Forcing a reinstall of cffi alongside soundfile is the
    /// smallest hammer that actually fixes it. Path is gated on the
    /// missing_audio_backend code, so we only ever take it when audio
    /// backends are demonstrably empty, never when things are working.
    @discardableResult
    static func installAudioBackend(pythonPath: String) async throws -> String {
        let result = try await runPython(
            path: pythonPath,
            arguments: ["-m", "pip", "install", "--user",
                        "--force-reinstall", "--no-cache-dir",
                        "cffi", "soundfile"]
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
        // The pyannote `soundfile`/libsndfile backend can't read AAC/.m4a,
        // so decode compressed recordings to a temp WAV first. WAV inputs
        // pass straight through. The temp file is cleaned up on exit.
        var pythonInputURL = wavURL
        var tempWAVToCleanUp: URL?
        if wavURL.pathExtension.lowercased() != "wav" {
            pythonInputURL = try AudioCompressor.decodeToTempWAV(wavURL)
            tempWAVToCleanUp = pythonInputURL
        }
        defer {
            if let temp = tempWAVToCleanUp { try? FileManager.default.removeItem(at: temp) }
        }
        let resolvedPython = resolvePython(userConfigured: pythonPath)
        let extraEnv = pythonEnvironment()

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
            path: resolvedPython,
            arguments: ["-c", script, pythonInputURL.path, modelsPath],
            environment: extraEnv
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

    /// Outcome of `healthCheck`. `ok == true` means torch + pyannote import,
    /// the bundled config.yaml parses, AND the pipeline instantiates from
    /// the bundled weights — i.e. real diarization runs will work without
    /// any first-call setup penalty surprising the user mid-recording.
    /// `code` is a stable identifier for recoverable failure modes so the
    /// Swift side can attempt targeted remediation (e.g. install soundfile
    /// on missing_audio_backend) instead of free-text matching.
    /// `module` is set when `code == "missing_module"` — the specific
    /// import path that failed — so Swift can pip-install it.
    struct HealthCheckResult: Codable {
        let ok: Bool
        let error: String?
        let code: String?
        let module: String?

        init(ok: Bool, error: String? = nil, code: String? = nil, module: String? = nil) {
            self.ok = ok
            self.error = error
            self.code = code
            self.module = module
        }
    }

    /// Lightweight diagnostic that runs at app launch (and on demand from
    /// Settings). Imports the Python stack, loads the bundled config, and
    /// instantiates `Pipeline.from_pretrained` against the bundled model
    /// weights, but does NOT process any audio. Typical run time is a
    /// couple of seconds — fast enough to fire on every launch without
    /// blocking the UI thread (callers should await it on a background
    /// task and surface the result async).
    static func healthCheck(pythonPath: String) async throws -> HealthCheckResult {
        guard let modelsPath = bundledModelsPath else {
            return HealthCheckResult(ok: false, error: "Bundled diarization models not found in app")
        }

        // Same speechbrain LazyModule + torch.load weights_only patches as
        // `diarize()` — without them pyannote crashes during pipeline init
        // because the pytorch_lightning stack inspection triggers optional
        // import paths we don't actually use.
        //
        // The torchaudio pre-flight is the one structural addition: pyannote
        // crashes at *import time* with IndexError if torchaudio reports zero
        // audio backends (pyannote/audio/core/io.py does `backends[0]`).
        // Catching this before the pyannote import lets us return a stable
        // `missing_audio_backend` code that Swift can recover from by
        // `pip install soundfile`-ing on the user's behalf.
        let script = """
        import json, sys, os, types, tempfile

        result = {"ok": False, "error": None, "code": None, "module": None}

        def _emit(code, error):
            result["code"] = code
            result["error"] = error
            json.dump(result, sys.stdout)
            sys.exit(0)

        try:
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

            try:
                import torch
            except ImportError as e:
                _emit("missing_torch", f"torch not installed: {e}")

            try:
                import torchaudio
                backends = torchaudio.list_audio_backends()
            except ImportError as e:
                _emit("missing_torchaudio", f"torchaudio not installed: {e}")

            if not backends:
                _emit("missing_audio_backend",
                      "torchaudio reports zero audio backends; soundfile needed")

            _orig_torch_load = torch.load
            def _patched_torch_load(*args, **kwargs):
                kwargs["weights_only"] = False
                return _orig_torch_load(*args, **kwargs)
            torch.load = _patched_torch_load

            try:
                from pyannote.audio import Pipeline
            except ImportError as e:
                # Re-raised below by the outer handler; both top-level
                # "pyannote not installed" and "transitive dep X missing"
                # land there with consistent code/module population.
                raise

            models_dir = sys.argv[1]
            config_path = os.path.join(models_dir, "config.yaml")
            with open(config_path) as f:
                config_text = f.read().replace("__MODELS_DIR__", models_dir)

            tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False)
            tmp.write(config_text)
            tmp.close()

            try:
                Pipeline.from_pretrained(tmp.name)
                result["ok"] = True
            finally:
                os.unlink(tmp.name)
        except ModuleNotFoundError as e:
            # ModuleNotFoundError can surface anywhere — during the
            # `from pyannote.audio` import OR later inside
            # Pipeline.from_pretrained when a sub-pipeline lazily imports
            # something (matplotlib, pandas, sklearn extras). `.name` is
            # always the offending top-level package. We promote this to a
            # stable `missing_module` code so Swift can pip-install just
            # that wheel into the user-writable site-packages and retry.
            mod = getattr(e, "name", None) or ""
            if mod and mod != "pyannote" and not mod.startswith("pyannote."):
                result["module"] = mod
                result["code"] = "missing_module"
                result["error"] = f"pyannote dep missing: {mod}"
            else:
                result["code"] = "missing_pyannote"
                result["error"] = f"pyannote.audio not installed: {e}"
        except Exception as e:
            result["code"] = "unknown"
            result["error"] = f"{type(e).__name__}: {e}"

        json.dump(result, sys.stdout)
        """

        let result = try await runPython(
            path: resolvePython(userConfigured: pythonPath),
            arguments: ["-c", script, modelsPath],
            environment: pythonEnvironment()
        )
        guard !result.stdout.isEmpty else {
            let errMsg = String(data: result.stderr, encoding: .utf8) ?? "no output"
            return HealthCheckResult(ok: false, error: errMsg)
        }
        return try JSONDecoder().decode(HealthCheckResult.self, from: result.stdout)
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
            path: resolvePython(userConfigured: pythonPath),
            arguments: ["-c", script],
            environment: pythonEnvironment()
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
