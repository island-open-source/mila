import Foundation
import CoreServices

/// Thin FSEvents wrapper that fires `onChange` whenever anything under a
/// directory tree changes. Used to notice when `voicememod` drops a freshly
/// iCloud-synced recording into the Voice Memos folder so Mila can pick it
/// up without the user lifting a finger.
///
/// FSEvents (rather than a `DispatchSource` vnode source) because vnode
/// sources watch a single file descriptor and miss new files created deeper
/// in the tree — exactly the event we care about. The callback is coalesced
/// (`latency`) so a burst of sync writes triggers one `onChange`.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "io.island.mila.voicememos.fsevents")
    private let onChange: () -> Void

    init(path: String, latency: CFTimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.path = path
        self.latency = latency
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        // FSEventStreamStart "ought to always succeed" but can fail under
        // resource pressure. On failure, tear the stream down and leave
        // `self.stream` nil so a later `start()` can retry instead of looking
        // active while no events ever arrive.
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)  // blocks until in-flight callbacks drain
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
