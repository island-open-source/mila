import Foundation
import Combine

@MainActor
final class DiarizationSettings: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "diarization.enabled")
            if isEnabled && pythonFound && lastVerifyResult == nil && !isVerified {
                Task { await checkDeps() }
            }
            if isEnabled, hasBundledRuntime {
                Task { await bootstrap.bootstrapIfNeeded() }
            }
        }
    }

    /// Orchestrates the bundled-python + runtime-torch-install flow. The
    /// instance is alive for the lifetime of DiarizationSettings so the
    /// Settings UI can observe its `stage` directly via .environmentObject.
    let bootstrap: DiarizationBootstrap

    /// True iff the .app shipped with a bundled PythonRuntime — when true
    /// we run the bundled-python flow exclusively (no pip-install onto
    /// system python), otherwise we fall back to the legacy auto-recover.
    /// Reads from the injected bootstrap so tests that swap the bootstrap's
    /// paths see a consistent gate.
    var hasBundledRuntime: Bool {
        bootstrap.hasBundledPython
    }
    @Published var pythonPath: String {
        didSet {
            defaults.set(pythonPath, forKey: "diarization.pythonPath")
            pythonFound = FileManager.default.fileExists(atPath: pythonPath)
            invalidateIfChanged()
        }
    }

    private let defaults: UserDefaults
    @Published private(set) var pythonFound: Bool

    init(defaults: UserDefaults = .standard,
         bootstrap: DiarizationBootstrap? = nil) {
        self.defaults = defaults
        // Build the default bootstrap inside the init rather than via a
        // default-argument expression — `DiarizationBootstrap.init` is
        // `@MainActor`-isolated, and Swift evaluates default arguments in
        // the caller's isolation context, which made the previous default
        // unusable from non-isolated entry points.
        self.bootstrap = bootstrap ?? DiarizationBootstrap()
        self.isEnabled = defaults.bool(forKey: "diarization.enabled")
        let path = defaults.string(forKey: "diarization.pythonPath") ?? "/usr/bin/python3"
        self.pythonPath = path
        self._pythonFound = Published(initialValue: FileManager.default.fileExists(atPath: path))
        restoreVerifiedState()
        // didSet on `isEnabled` doesn't fire from `init`, so when the user
        // had previously enabled diarization AND torch is already installed
        // in the user-writable site-packages, `bootstrap.isReady` would
        // stay at its default `false`. That made `isConfigured` silently
        // return false on the first transcription after launch — the
        // recording would complete with no speaker labels. Run the cheap
        // file-existence check here so the gate matches reality at startup.
        self.bootstrap.refreshReadyState()
        if isEnabled && pythonFound && verificationStatus != .verified {
            Task { await checkDeps() }
        }
    }

    private var isVerified: Bool {
        defaults.bool(forKey: "diarization.verified")
    }

    private func persistVerified() {
        defaults.set(true, forKey: "diarization.verified")
        defaults.set(pythonPath, forKey: "diarization.verifiedPythonPath")
    }

    private func clearVerified() {
        defaults.set(false, forKey: "diarization.verified")
        defaults.removeObject(forKey: "diarization.verifiedPythonPath")
    }

    private func invalidateIfChanged() {
        let savedPath = defaults.string(forKey: "diarization.verifiedPythonPath") ?? ""
        if pythonPath != savedPath {
            clearVerified()
            verificationStatus = .disabled
            lastVerifyResult = nil
        }
    }

    private func restoreVerifiedState() {
        guard isEnabled && isVerified else { return }
        let savedPath = defaults.string(forKey: "diarization.verifiedPythonPath") ?? ""
        if pythonPath == savedPath && pythonFound {
            verificationStatus = .verified
        }
    }

    var isConfigured: Bool {
        guard isEnabled else { return false }
        // On the bundled-runtime flow, "configured" means torch has been
        // runtime-downloaded too. Until then, transcription proceeds
        // without speaker labels rather than failing or blocking — the
        // user keeps using the app while bootstrap completes; later
        // recordings get speakers automatically.
        if hasBundledRuntime { return bootstrap.isReady }
        return status.isGood
    }

    enum SetupStatus: Equatable {
        case disabled
        case checking
        case missingDeps
        case pythonNotFound
        case notVerified
        case verifying
        case verified
        case verificationFailed(String)

        var label: String {
            switch self {
            case .disabled:                    return "Disabled"
            case .checking:                    return "Checking…"
            case .missingDeps:                 return "Setup needed"
            case .pythonNotFound:              return "Python not found"
            case .notVerified:                 return "Setup needed"
            case .verifying:                   return "Verifying…"
            case .verified:                    return "Ready"
            case .verificationFailed(let msg): return msg
            }
        }

        var sfSymbol: String {
            switch self {
            case .disabled:              return "circle"
            case .checking:              return "arrow.triangle.2.circlepath"
            case .missingDeps:           return "exclamationmark.triangle.fill"
            case .pythonNotFound:        return "exclamationmark.triangle.fill"
            case .notVerified:           return "questionmark.circle.fill"
            case .verifying:             return "arrow.triangle.2.circlepath"
            case .verified:              return "checkmark.circle.fill"
            case .verificationFailed:    return "xmark.circle.fill"
            }
        }

        var color: StatusColor {
            switch self {
            case .disabled, .checking, .notVerified:
                return .secondary
            case .missingDeps, .pythonNotFound:
                return .orange
            case .verified:
                return .green
            case .verifying:
                return .secondary
            case .verificationFailed:
                return .red
            }
        }

        enum StatusColor {
            case secondary, orange, green, red
        }

        var isGood: Bool {
            if case .verified = self { return true }
            return false
        }
    }

    @Published private(set) var verificationStatus: SetupStatus = .disabled
    @Published private(set) var lastVerifyResult: SpeakerDiarizer.VerifyResult?
    @Published private(set) var isInstalling = false
    @Published private(set) var installLog: String?

    /// Result of the most recent lightweight `SpeakerDiarizer.healthCheck`,
    /// or nil if it hasn't run yet this session. Drives the "Speaker
    /// detection: Ready / Unavailable" badge in Settings.
    @Published private(set) var healthCheckResult: SpeakerDiarizer.HealthCheckResult?
    @Published private(set) var isHealthChecking = false

    var status: SetupStatus {
        guard isEnabled else { return .disabled }
        guard pythonFound else { return .pythonNotFound }
        if case .checking = verificationStatus { return .checking }
        if case .verifying = verificationStatus { return .verifying }
        if isInstalling { return .checking }
        if case .verified = verificationStatus { return .verified }
        if needsDepsInstall { return .missingDeps }
        if let result = lastVerifyResult, result.pyannoteInstalled && result.torchInstalled {
            if case .verificationFailed(let msg) = verificationStatus {
                return .verificationFailed(msg)
            }
            return .notVerified
        }
        if case .verificationFailed(let msg) = verificationStatus {
            return .verificationFailed(msg)
        }
        return .notVerified
    }

    var canVerify: Bool {
        isEnabled && pythonFound && !needsDepsInstall
    }

    var needsDepsInstall: Bool {
        guard let result = lastVerifyResult else { return false }
        return !result.pyannoteInstalled || !result.torchInstalled
    }

    var needsDepsUpgrade: Bool { false }

    func checkDeps() async {
        verificationStatus = .checking
        lastVerifyResult = nil
        do {
            let result = try await SpeakerDiarizer.verifySetup(pythonPath: pythonPath)
            lastVerifyResult = result
            if result.allGood {
                verificationStatus = .verified
                persistVerified()
            } else {
                verificationStatus = .disabled
                clearVerified()
            }
        } catch {
            verificationStatus = .disabled
            clearVerified()
        }
    }

    func installDependencies() async {
        isInstalling = true
        installLog = nil
        do {
            let log = try await SpeakerDiarizer.installDependencies(pythonPath: pythonPath)
            installLog = log
            await checkDeps()
        } catch {
            installLog = "Install failed: \(error.localizedDescription)"
        }
        isInstalling = false
    }

    /// Lightweight launch-time + on-demand diagnostic. Verifies that the
    /// Python stack imports AND the bundled diarization pipeline can be
    /// instantiated. Result is exposed via `healthCheckResult` and shown
    /// in Settings as a single ready/unavailable badge — the user never
    /// has to look at a multi-step setup flow.
    ///
    /// Auto-recovery: if the check returns `missing_audio_backend`, we
    /// pip-install `soundfile` (the smallest fix) and re-run once. This is
    /// the most common reason a working pyannote install still fails:
    /// `pip install pyannote.audio` doesn't pull a torchaudio backend, so
    /// pyannote crashes at import with `IndexError` deep inside its IO
    /// initialisation. We don't want the user staring at that.
    func runHealthCheck() async {
        // The bundled python3.11 ships with the .app and is always
        // present on release builds — only fail the precondition when
        // we have neither the bundle nor a working user-configured
        // python. (`pythonFound` only checks the user-configured path
        // and would otherwise mask the bundled-runtime case where the
        // user's /usr/bin/python3 has been removed or misconfigured.)
        guard pythonFound || hasBundledRuntime else {
            healthCheckResult = SpeakerDiarizer.HealthCheckResult(
                ok: false, error: "Python not found at \(pythonPath) and no bundled runtime present"
            )
            return
        }
        isHealthChecking = true
        defer { isHealthChecking = false }

        // Iteratively self-heal `missing_module` failures up to a cap.
        // Each pass installs the one specific module the script reports,
        // then re-runs the check. New module name on the next pass means
        // the import chain advanced past the previous one; the cap exists
        // so a genuinely-broken state can't pip-loop forever.
        if hasBundledRuntime, isEnabled {
            var installed: Set<String> = []
            var lastCode: String? = nil
            var nuclearAttempted = false
            iteration: for _ in 0..<10 {
                let result = await runHealthCheckOnce()
                if result.ok { healthCheckResult = result; return }

                switch result.code {
                case "missing_module":
                    guard let module = result.module,
                          !installed.contains(module) else { break iteration }
                    isInstalling = true
                    installed.insert(module)
                    do {
                        _ = try await SpeakerDiarizer.installMissingModule(
                            pythonPath: pythonPath,
                            userSitePackages: DiarizationBootstrap.userSitePackages.path,
                            module: module
                        )
                    } catch {
                        healthCheckResult = SpeakerDiarizer.HealthCheckResult(
                            ok: false,
                            error: "Auto-install of \(module) failed: \(error.localizedDescription)",
                            code: result.code,
                            module: module
                        )
                        isInstalling = false
                        return
                    }
                    isInstalling = false
                    lastCode = result.code
                default:
                    // Non-recoverable error code (e.g. "unknown" — common
                    // when pyannote internally swallows a ModuleNotFoundError
                    // and re-raises an ambiguous "partially initialized
                    // module" ImportError). Wipe the user dir and re-run
                    // bootstrap once. This is the "reset everything if it's
                    // in a messed up state" path — we only take it once per
                    // call to avoid infinite loops on a genuinely broken
                    // environment.
                    if nuclearAttempted {
                        healthCheckResult = result
                        return
                    }
                    nuclearAttempted = true
                    isInstalling = true
                    await bootstrap.nuclearRepair()
                    isInstalling = false
                    installed.removeAll()
                    lastCode = result.code
                }
                _ = lastCode  // suppress unused-variable warning
            }
        }

        let first = await runHealthCheckOnce()
        if first.ok {
            healthCheckResult = first
            return
        }

        // Self-heal recoverable failures: the app installs what it needs
        // rather than asking the user to. We only re-run installation when
        // the structured error code says it's worth trying — random
        // pip-install loops on unknown errors would be worse than just
        // surfacing the error.
        //
        // Two flows:
        //  • Bundled runtime present → all deps except torch ship in the
        //    .app; missing_torch means "run DiarizationBootstrap to fetch
        //    the wheel". Other codes shouldn't happen on the bundled path;
        //    if they do, surface the error rather than pip-installing
        //    into a read-only bundle.
        //  • No bundle (legacy) → pip into the user's system python.
        //    Gated on isEnabled so fresh users don't get a multi-GB
        //    download for a feature they never opted in to.
        let remediator: ((String) async throws -> Void)?
        if hasBundledRuntime {
            if isEnabled, first.code == "missing_torch" || first.code == "missing_torchaudio" {
                isInstalling = true
                remediator = { [weak self] _ in
                    await self?.bootstrap.bootstrapIfNeeded()
                }
            } else if isEnabled, first.code == "missing_module", let module = first.module {
                // A transitive pyannote dep got excluded from the bundle (or
                // was bundled but won't import for some reason). Pip the
                // exact missing module into the user-writable site-packages
                // so PYTHONPATH picks it up on the retry. No torch reinstall,
                // no full pyannote reinstall — minimal, targeted.
                isInstalling = true
                remediator = { python in
                    _ = try await SpeakerDiarizer.installMissingModule(
                        pythonPath: python,
                        userSitePackages: DiarizationBootstrap.userSitePackages.path,
                        module: module
                    )
                }
            } else {
                remediator = nil
            }
        } else {
            switch first.code {
            case "missing_audio_backend" where isEnabled:
                remediator = { _ = try await SpeakerDiarizer.installAudioBackend(pythonPath: $0) }
            case "missing_torch", "missing_torchaudio", "missing_pyannote":
                guard isEnabled else {
                    remediator = nil
                    break
                }
                isInstalling = true
                remediator = { _ = try await SpeakerDiarizer.installDependencies(pythonPath: $0) }
            default:
                remediator = nil
            }
        }

        guard let remediator else {
            healthCheckResult = first
            return
        }

        defer { isInstalling = false }
        do {
            try await remediator(pythonPath)
        } catch {
            healthCheckResult = SpeakerDiarizer.HealthCheckResult(
                ok: false,
                error: "Auto-install failed: \(error.localizedDescription)",
                code: first.code
            )
            return
        }
        healthCheckResult = await runHealthCheckOnce()
    }

    private func runHealthCheckOnce() async -> SpeakerDiarizer.HealthCheckResult {
        do {
            return try await SpeakerDiarizer.healthCheck(pythonPath: pythonPath)
        } catch {
            return SpeakerDiarizer.HealthCheckResult(
                ok: false, error: error.localizedDescription
            )
        }
    }

    func verify() async {
        verificationStatus = .verifying
        lastVerifyResult = nil
        do {
            let result = try await SpeakerDiarizer.verifySetup(pythonPath: pythonPath)
            lastVerifyResult = result

            if result.allGood {
                verificationStatus = .verified
                persistVerified()
            } else {
                clearVerified()
                if !result.pyannoteInstalled {
                    verificationStatus = .verificationFailed("pyannote.audio not installed")
                } else if !result.torchInstalled {
                    verificationStatus = .verificationFailed("torch not installed")
                }
            }
        } catch {
            verificationStatus = .verificationFailed("Verification failed")
            clearVerified()
        }
    }
}
