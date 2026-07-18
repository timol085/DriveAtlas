#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// Notifies when external drives are mounted and unmounted.
///
/// Uses `NSWorkspace`'s mount notifications rather than DiskArbitration directly.
/// The plan called for DiskArbitration, but it's the wrong altitude here: it
/// reports *disks*, and we only care about *mounted volumes* — which is precisely
/// what NSWorkspace hands us, already resolved to a URL. DiskArbitration would
/// mean C callbacks with manual context pointers and then resolving volumes
/// ourselves, for no behavioural gain. If we later need to react to a disk that
/// appears but fails to mount, that's the point to reach for it.
///
/// Requires a running run loop (an app, or `RunLoop.main.run()` in a CLI).
@MainActor
public final class VolumeWatcher {

    public enum Event: Sendable {
        case mounted(MountedVolume)
        /// Unmount only gives us the path — the drive's already gone by then.
        case unmounted(URL)
    }

    private var observers: [NSObjectProtocol] = []
    private let onEvent: (Event) -> Void

    public init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    /// Begins watching. Pass `emitExisting: true` to also report drives that were
    /// already plugged in at launch — otherwise a drive connected before the app
    /// started is invisible until you unplug and replug it.
    public func start(emitExisting: Bool = true) {
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.handleMount(url) }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.onEvent(.unmounted(url)) }
        })
        #endif

        if emitExisting {
            for volume in MountedVolume.currentlyMounted() {
                onEvent(.mounted(volume))
            }
        }
    }

    public func stop() {
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        #endif
        observers.removeAll()
    }

    private func handleMount(_ url: URL) {
        guard let metadata = try? DriveMetadata.read(volumeURL: url) else { return }
        // Silently ignore disk images and internal volumes — mounting a DMG
        // shouldn't put anything in the catalog.
        guard metadata.isCatalogableDrive else { return }
        onEvent(.mounted(MountedVolume(url: url, metadata: metadata)))
    }

    // No `deinit` cleanup: a nonisolated deinit can't touch `@MainActor` state
    // under Swift 6. Callers must call `stop()`. The observer blocks hold `self`
    // weakly, so an un-stopped watcher leaks two tokens rather than misbehaving —
    // and in practice the watcher lives as long as the app does.
}
