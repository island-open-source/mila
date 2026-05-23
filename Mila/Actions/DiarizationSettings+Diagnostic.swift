import Foundation

/// Provides the diagnostic-report adapter for `DiarizationSettings` so
/// `DiagnosticReporter` can include the speaker-detection pipeline state
/// without importing the model directly. Kept in a separate file so the
/// model stays focused on its persistence + lifecycle responsibilities.
extension DiarizationSettings: DiagnosticSnapshotProvider {
    /// Plain-text snapshot of the diarization pipeline's current state.
    /// Includes whether the user enabled it, the resolved python path,
    /// the last health-check verdict, and any associated error. Safe to
    /// share — no auth tokens, no paths into the user's home dir beyond
    /// what they configured themselves.
    func diagnosticSnapshot() async -> String {
        // Hop to the main actor since DiarizationSettings is @MainActor
        // and the reporter is too — but it goes through a sendable
        // protocol so the actor isolation has to be made explicit here.
        await MainActor.run {
            var lines: [String] = []
            lines.append("enabled:             \(isEnabled)")
            lines.append("has_bundled_runtime: \(hasBundledRuntime)")
            lines.append("python_path:         \(pythonPath.isEmpty ? "<none>" : pythonPath)")
            lines.append("python_found:        \(pythonFound)")
            lines.append("verification_status: \(verificationStatus)")
            lines.append("status:              \(status)")
            lines.append("is_health_checking:  \(isHealthChecking)")
            if let result = healthCheckResult {
                lines.append("last_health_check.ok:    \(result.ok)")
                if let err = result.error {
                    lines.append("last_health_check.error: \(err)")
                }
            } else {
                lines.append("last_health_check:   <not run>")
            }
            lines.append("bootstrap_stage:     \(String(describing: bootstrap.stage))")
            return lines.joined(separator: "\n")
        }
    }
}
