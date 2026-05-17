import Foundation

/// Orchestrates the first-launch download + install of the torch wheel into a
/// user-writable site-packages directory. Everything else needed for speaker
/// diarization (the python-build-standalone interpreter + pyannote.audio +
/// numpy/scipy/etc.) ships bundled in `IslandWhisper.app/Contents/Resources/
/// PythonRuntime/`. torch is ~60 MB compressed / ~600 MB unpacked and would
/// blow our DMG budget, so it's a runtime download.
///
/// We pip-install torch into a *separate* site-packages dir under
/// `~/Library/Application Support/IslandWhisper/torch-site-packages/`. The
/// bundled site-packages is inside the .app and not writable (would also
/// require ad-hoc resigning of any binaries written into a signed bundle).
/// Both directories get added to `sys.path` when SpeakerDiarizer's subprocess
/// runs, so `import torch` resolves into the writable dir while `import
/// pyannote` resolves into the bundled one.
@MainActor
final class DiarizationBootstrap: ObservableObject {
    /// Pinned versions — must stay aligned with the bundled pyannote.audio
    /// (3.3.x). Newer torch (>= 2.6) changes the `weights_only` default and
    /// breaks pyannote's checkpoint loading; we patch around it at import
    /// but the saner pin is to stay on 2.2.x until pyannote follows.
    static let torchVersion = "2.2.2"
    static let torchaudioVersion = "2.2.2"

    /// Wheel URLs on PyTorch's CPU index. Arm64-only for now (the app runs
    /// universally but the bundled Python is arm64; an x86_64 add is a
    /// follow-up). We download both torch AND torchaudio — pyannote.audio
    /// uses torchaudio for audio I/O (`torchaudio.list_audio_backends()`,
    /// `torchaudio.load()`), so installing only torch produces a broken
    /// pipeline with a confusing `missing_torchaudio` health-check code.
    static let wheelURLs: [URL] = [
        URL(string: "https://download.pytorch.org/whl/cpu/torch-\(torchVersion)-cp311-none-macosx_11_0_arm64.whl")!,
        URL(string: "https://download.pytorch.org/whl/cpu/torchaudio-\(torchaudioVersion)-cp311-cp311-macosx_11_0_arm64.whl")!,
    ]

    /// Extra PyPI specs to install into the user-writable site-packages
    /// after the wheels download. These don't have a fixed wheel URL we
    /// pin; pip resolves them at install time.
    ///
    /// `numpy<2`: torch 2.2.x was compiled against the numpy 1.x C ABI.
    /// The bundled site-packages ships numpy 2.4 because that's what
    /// pyannote's transitive deps resolve to today, but torch can't
    /// consume it at runtime — first call raises
    /// `RuntimeError: Numpy is not available`. Installing numpy 1.26.x
    /// into the user dir works because PYTHONPATH puts user FIRST.
    ///
    /// `matplotlib` + chain: pyannote's audiomentations + pyannote-metrics
    /// lazily import matplotlib deep inside `Pipeline.from_pretrained`. If
    /// matplotlib (or one of its own deps: Pillow / pyparsing / cycler /
    /// kiwisolver / fonttools) is missing, pyannote sometimes swallows the
    /// real ModuleNotFoundError and re-raises an ambiguous "cannot import
    /// name '_c_internal_utils' from partially initialized module
    /// 'matplotlib'" — which is NOT a ModuleNotFoundError, so the runtime
    /// self-heal can't determine which module to fetch. Pre-installing
    /// the whole chain up front sidesteps that failure path entirely.
    /// (The runtime self-heal still handles any *other* transitive dep
    /// that may surface later.)
    static let extraInstallSpecs: [String] = [
        "numpy<2",
        "matplotlib",
        "Pillow",
        "pyparsing",
        "cycler",
        "kiwisolver",
        "fonttools",
    ]

    enum Stage: Equatable {
        case notStarted
        case checking
        case downloadingTorch(progress: Double)
        case installingTorch
        case signing
        case ready
        case failed(String)
    }

    @Published private(set) var stage: Stage = .notStarted

    /// True iff torch + torchaudio are already installed under the user-
    /// writable site-packages dir AND the bundled PythonRuntime exists.
    @Published private(set) var isReady: Bool = false

    private let fileManager = FileManager.default

    /// Bundled PythonRuntime location inside the .app. Nil if the app was
    /// built without a bundle (e.g. a dev build before `make
    /// bundle-diarization` has run) — callers can fall back to system
    /// python in that case. `nonisolated` so SpeakerDiarizer's detached
    /// subprocess tasks can read it without bouncing through the main
    /// actor.
    nonisolated static var bundledPythonPath: String? {
        guard let root = Bundle.main.resourcePath else { return nil }
        let candidate = "\(root)/PythonRuntime/python/bin/python3.11"
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    /// Bundled site-packages (read-only, inside the .app).
    nonisolated static var bundledSitePackages: String? {
        guard let root = Bundle.main.resourcePath else { return nil }
        let candidate = "\(root)/PythonRuntime/python/site-packages"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return candidate
    }

    /// User-writable site-packages for runtime-installed torch. Created on
    /// demand. Living under Application Support means upgrades don't lose
    /// the install — only an explicit reinstall clears it.
    nonisolated static var userSitePackages: URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("IslandWhisper", isDirectory: true)
            .appendingPathComponent("torch-site-packages", isDirectory: true)
    }

    /// Returns the PYTHONPATH the SpeakerDiarizer subprocess should run
    /// with — **user dir first**, bundled site-packages second. Order
    /// matters: when the bundle ships a package that has a runtime ABI
    /// mismatch (e.g. numpy 2.x with torch 2.2.x which needs numpy <2),
    /// the runtime self-heal pip-installs the correct version into the
    /// user dir and we want that to win on import lookup. The bundle is
    /// the fallback for everything we DIDN'T need to override.
    ///
    /// Returns an empty string when no bundle is present, so legacy
    /// users keep whatever PYTHONPATH the system gave them.
    /// `pythonEnvironment()` then omits the variable entirely rather
    /// than clobbering it.
    nonisolated static var combinedPythonPath: String {
        guard let bundled = bundledSitePackages else { return "" }
        return "\(userSitePackages.path):\(bundled)"
    }

    /// True iff `torch/__init__.py` AND `torchaudio/__init__.py` exist in
    /// the user-writable site-packages — cheap check, no subprocess. We
    /// don't verify the installation's integrity beyond presence; a
    /// corrupted install will fail at the next subprocess run and the
    /// user can hit "Reinstall" to redo this flow.
    func refreshReadyState() {
        let torchInit = Self.userSitePackages
            .appendingPathComponent("torch")
            .appendingPathComponent("__init__.py")
        let torchaudioInit = Self.userSitePackages
            .appendingPathComponent("torchaudio")
            .appendingPathComponent("__init__.py")
        isReady = Self.bundledPythonPath != nil
            && fileManager.fileExists(atPath: torchInit.path)
            && fileManager.fileExists(atPath: torchaudioInit.path)
        if isReady, stage == .notStarted { stage = .ready }
    }

    /// Kick off the bootstrap. Idempotent — if torch is already installed,
    /// returns without doing anything.
    func bootstrapIfNeeded() async {
        refreshReadyState()
        if isReady { return }

        guard let python = Self.bundledPythonPath else {
            stage = .failed("Bundled PythonRuntime missing from .app — run `make bundle-diarization` and rebuild.")
            return
        }

        do {
            try fileManager.createDirectory(at: Self.userSitePackages,
                                            withIntermediateDirectories: true)

            // Download all wheels first so the progress bar reflects total
            // bytes, then install. Both fit in ~62 MB; torchaudio is the
            // smaller of the two (~1.5 MB) but ordering matters for the
            // progress reporting.
            stage = .downloadingTorch(progress: 0)
            var downloaded: [URL] = []
            for (idx, url) in Self.wheelURLs.enumerated() {
                let path = try await downloadWheel(from: url) { perFileProgress in
                    let overall = (Double(idx) + perFileProgress) / Double(Self.wheelURLs.count)
                    Task { @MainActor in
                        self.stage = .downloadingTorch(progress: overall)
                    }
                }
                downloaded.append(path)
            }

            stage = .installingTorch
            try await runPipInstall(python: python, wheels: downloaded)
            for path in downloaded { try? fileManager.removeItem(at: path) }

            // Install the extra PyPI specs (numpy<2 etc.) into the same
            // user-writable site-packages. These can't be pinned to a wheel
            // URL the way torch is, but pip resolves them fine at runtime.
            for spec in Self.extraInstallSpecs {
                try await runPipInstallSpec(python: python, spec: spec)
            }

            stage = .signing
            try await signFreshDylibs()

            refreshReadyState()
            stage = isReady ? .ready : .failed("Install completed but torch still not importable.")
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Resets the user-writable site-packages and re-runs bootstrap. For
    /// the manual "Reinstall" button in Settings.
    func reinstall() async {
        try? fileManager.removeItem(at: Self.userSitePackages)
        isReady = false
        stage = .notStarted
        await bootstrapIfNeeded()
    }

    /// Wipe + re-bootstrap. Same as `reinstall()`. Exposed as a separate
    /// name so the iterative self-heal can request it without the UI
    /// affordance ("Reinstall" button) reading semantically odd.
    func nuclearRepair() async {
        await reinstall()
    }

    // MARK: - Internals

    private func downloadWheel(from sourceURL: URL,
                               progress: @escaping (Double) -> Void) async throws -> URL {
        let session = URLSession.shared
        let (downloadURL, response) = try await session.download(from: sourceURL, progress: progress)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "DiarizationBootstrap", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "wheel download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            ])
        }
        // Move out of the temp download path before we hand it to pip — the
        // session deletes the temp file when this scope exits.
        let dest = fileManager.temporaryDirectory
            .appendingPathComponent(sourceURL.lastPathComponent)
        try? fileManager.removeItem(at: dest)
        try fileManager.moveItem(at: downloadURL, to: dest)
        return dest
    }

    /// Pip-install a PyPI spec (e.g. "numpy<2") into the user-writable
    /// site-packages. Same `--no-deps --only-binary` flags as the wheel
    /// install path — we don't want pip pulling in adjacent packages we
    /// haven't planned for.
    private func runPipInstallSpec(python: String, spec: String) async throws {
        let targetPath = Self.userSitePackages.path
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [
                "-m", "pip", "install",
                "--target", targetPath,
                "--upgrade",
                "--no-deps",
                "--only-binary=:all:",
                spec,
            ]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()
            try process.run()
            let stderrRead = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            process.waitUntilExit()
            let stderrData = await stderrRead.value
            if process.terminationStatus != 0 {
                let msg = String(data: stderrData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                throw NSError(domain: "DiarizationBootstrap", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "pip install \(spec) failed: \(msg.prefix(500))"
                ])
            }
        }.value
    }

    private func runPipInstall(python: String, wheels: [URL]) async throws {
        let targetPath = Self.userSitePackages.path
        let wheelPaths = wheels.map(\.path)
        // Detach the blocking subprocess work to a background task —
        // pip-installing torch (~60 MB wheel, ~600 MB on-disk) can run for
        // a minute and we're on @MainActor. `process.waitUntilExit()` on
        // the main thread would freeze the entire UI. Same pattern
        // SpeakerDiarizer.runPython uses.
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [
                "-m", "pip", "install",
                "--target", targetPath,
                "--no-deps",
                "--only-binary=:all:",
            ] + wheelPaths
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()  // discard
            try process.run()
            let stderrRead = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            process.waitUntilExit()
            let stderrData = await stderrRead.value
            if process.terminationStatus != 0 {
                let msg = String(data: stderrData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                throw NSError(domain: "DiarizationBootstrap", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "pip install failed: \(msg.prefix(500))"
                ])
            }
        }.value
    }

    /// torch ships ~90 MB of un-signed dylibs in torch/lib/. macOS won't
    /// block dlopen from an ad-hoc-signed Python process today, but signing
    /// them keeps the install consistent with the bundled tree and avoids
    /// surprises if Apple tightens library validation later.
    private func signFreshDylibs() async throws {
        // Sign both torch/ and torchaudio/ — torch ships most of the
        // dylibs (~90 MB) but torchaudio has a handful of its own.
        let candidates = ["torch", "torchaudio"]
            .map { Self.userSitePackages.appendingPathComponent($0).path }
            .filter { fileManager.fileExists(atPath: $0) }
        guard !candidates.isEmpty else { return }
        let pathList = candidates.map { $0.shellEscaped }.joined(separator: " ")
        // codesign-find-xargs over ~hundreds of dylibs can take 10+ seconds.
        // Detach to keep the main thread responsive.
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                find \(pathList) \\( -name '*.so' -o -name '*.dylib' \\) -print0 \
                  | xargs -0 -n1 codesign -f -s - --timestamp=none
                """]
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            // Non-fatal: ad-hoc signing failures don't block functionality on
            // current macOS. If it ever does, we'll catch it at the diarize call.
        }.value
    }
}

private extension URLSession {
    /// `URLSession.download(from:)` with a synchronous progress callback.
    /// Captures progress via a delegate-less observer on the
    /// `URLSessionDownloadTask.progress`.
    func download(
        from url: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        var observer: NSKeyValueObservation?
        let result: (URL, URLResponse)
        do {
            result = try await withCheckedThrowingContinuation { continuation in
                let task = downloadTask(with: url) { tempURL, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let tempURL, let response {
                        // Move to a stable temp path before the closure
                        // returns — the system deletes tempURL on return.
                        let stable = FileManager.default.temporaryDirectory
                            .appendingPathComponent("torch-dl-\(UUID().uuidString).whl")
                        do {
                            try FileManager.default.moveItem(at: tempURL, to: stable)
                            continuation.resume(returning: (stable, response))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        continuation.resume(throwing: NSError(domain: "DiarizationBootstrap", code: 3))
                    }
                }
                observer = task.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                    progress(p.fractionCompleted)
                }
                task.resume()
            }
        }
        _ = observer  // keep alive until task completes
        return result
    }
}

private extension String {
    var shellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
