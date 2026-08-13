import CoreServices
import Foundation

/// Watches a mounted volume for content changes via FSEvents, so DriveAtlas
/// knows its catalog went stale *while the drive is still connected* — the
/// "changed it, then unplugged, assumed it updated" case.
///
/// FSEvents is the right tool over polling mtimes: it reports exactly which
/// directories changed, including deep ones, sidestepping the fact that macOS
/// directory mtimes don't propagate up the tree. We only need "did anything
/// change", so this coalesces a burst of events and fires a single callback.
///
/// Runs only while the app is running and the drive is mounted. Changes made
/// with DriveAtlas closed are caught by the automatic rescan on next connect
/// instead — that's the backstop this can't replace.
public final class DriveChangeWatcher {

    private let path: String
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    /// Changes confined entirely to these system directories are ignored —
    /// otherwise macOS maintaining its own Spotlight/Trash metadata would flag
    /// the drive as "changed" constantly.
    private static let ignoredComponents: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".DS_Store", "System Volume Information",
        "$RECYCLE.BIN",
    ]

    public init(volumePath: String, onChange: @escaping @Sendable () -> Void) {
        self.path = volumePath
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DriveChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes makes `paths` a CFArray<CFString>.
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths: list, count: count)
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        // 2s latency: coalesce a burst (e.g. pasting 500 photos) into one signal.
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0, flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(paths: [String], count: Int) {
        if Self.isRealChange(paths: paths) { onChange() }
    }

    /// True if at least one changed path is real content, not purely macOS
    /// metadata housekeeping (Spotlight index, Trash, `.DS_Store`, …). Extracted
    /// so the filter is unit-testable without FSEvents timing.
    static func isRealChange(paths: [String]) -> Bool {
        paths.contains { path in
            !path.split(separator: "/").contains { ignoredComponents.contains(String($0)) }
        }
    }
}
