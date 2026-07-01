import Foundation
import OSLog

/// Privacy markers mirroring `os.Logger`'s interpolation, so existing call
/// sites written as `log.error("… \(x, privacy: .public)")` compile unchanged
/// against `MilaLog`. For the file sink, `.private`/`.sensitive` values are
/// redacted; everything else is rendered.
enum MilaLogPrivacy { case `public`, `private`, auto, sensitive }

/// A log message built with the same string-interpolation syntax `os.Logger`
/// accepts (including the optional `, privacy:` argument). Renders to a plain
/// `String` for the stdout/file sink.
struct MilaLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    let rendered: String
    init(stringLiteral value: String) { rendered = value }
    init(stringInterpolation: Interpolation) { rendered = stringInterpolation.text }

    struct Interpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ s: String) { text += s }
        mutating func appendInterpolation<T>(_ value: T) { text += String(describing: value) }
        mutating func appendInterpolation<T>(_ value: T, privacy: MilaLogPrivacy) {
            text += (privacy == .private || privacy == .sensitive) ? "<private>" : String(describing: value)
        }
    }
}

/// Drop-in replacement for `os.Logger` that mirrors every entry to BOTH the
/// unified log (via `os.Logger`) AND stdout. Because `MilaApp.init()` redirects
/// stdout to `~/Library/Logs/Mila/mila.log`, this makes ALL subsystems —
/// VoiceMemos, RemoteWhisperEngine, ModelManager, etc. — show up in the file
/// log alongside the `print(...)`-based transcription diagnostics, instead of
/// being invisible in the unified log only.
struct MilaLog {
    let category: String
    private let osLogger: Logger

    init(category: String) {
        self.category = category
        osLogger = Logger(subsystem: "io.island.whisper.IslandWhisper", category: category)
    }

    func log(_ m: MilaLogMessage)     { osLogger.log("\(m.rendered, privacy: .public)");     sink("",       m) }
    func info(_ m: MilaLogMessage)    { osLogger.info("\(m.rendered, privacy: .public)");    sink("INFO",   m) }
    func notice(_ m: MilaLogMessage)  { osLogger.notice("\(m.rendered, privacy: .public)");  sink("NOTICE", m) }
    func debug(_ m: MilaLogMessage)   { osLogger.debug("\(m.rendered, privacy: .public)");   sink("DEBUG",  m) }
    func warning(_ m: MilaLogMessage) { osLogger.warning("\(m.rendered, privacy: .public)"); sink("WARN",   m) }
    func error(_ m: MilaLogMessage)   { osLogger.error("\(m.rendered, privacy: .public)");   sink("ERROR",  m) }

    private func sink(_ level: String, _ m: MilaLogMessage) {
        let tag = level.isEmpty ? "[\(category)]" : "[\(category)] \(level)"
        print("\(tag) \(m.rendered)")
    }
}
