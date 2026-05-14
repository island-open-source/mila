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
        }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: "diarization.enabled")
        let path = defaults.string(forKey: "diarization.pythonPath") ?? "/usr/bin/python3"
        self.pythonPath = path
        self._pythonFound = Published(initialValue: FileManager.default.fileExists(atPath: path))
        restoreVerifiedState()
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
        isEnabled && status.isGood
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
