import Foundation

/// Ties the watcher, metadata reader, store and scanner together.
///
/// This is the piece the UI (and the CLI's `watch` command) drives: start it, and
/// plugged-in drives get catalogued without further involvement.
@MainActor
public final class DriveCatalog {

    public enum Activity: Sendable {
        case driveConnected(name: String, alreadyKnown: Bool)
        case scanStarted(name: String)
        case scanProgress(name: String, foldersScanned: Int, currentPath: String)
        case scanFinished(name: String, summary: Scanner.Summary)
        case scanFailed(name: String, error: String)
        case driveDisconnected(path: String)
    }

    public let store: Store
    private let scanner: Scanner
    private var watcher: VolumeWatcher?
    private var onActivity: ((Activity) -> Void)?

    /// Drives currently being scanned, so a duplicate mount notification doesn't
    /// start a second concurrent walk of the same volume.
    private var scanning: Set<String> = []

    public init(store: Store) {
        self.store = store
        self.scanner = Scanner(store: store)
    }

    public func start(
        rescanKnownDrives: Bool = true,
        onActivity: @escaping (Activity) -> Void
    ) {
        self.onActivity = onActivity
        let watcher = VolumeWatcher { [weak self] event in
            guard let self else { return }
            switch event {
            case .mounted(let volume):
                self.handleMount(volume, rescanKnown: rescanKnownDrives)
            case .unmounted(let url):
                onActivity(.driveDisconnected(path: url.path))
            }
        }
        self.watcher = watcher
        watcher.start()
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Rescans a catalogued drive on demand, if its volume is currently mounted.
    ///
    /// Returns `false` when the drive isn't connected — a rescan needs the real
    /// filesystem, and the caller should say so rather than silently do nothing.
    /// Reuses the mount path end to end, so an on-demand rescan behaves exactly
    /// like a replug: sighting refreshed (free space included), then scanned.
    @discardableResult
    public func rescan(volumeUUID: String) -> Bool {
        guard let volume = MountedVolume.currentlyMounted()
            .first(where: { $0.stableIdentifier == volumeUUID })
        else { return false }
        handleMount(volume, rescanKnown: true)
        return true
    }

    private func handleMount(_ volume: MountedVolume, rescanKnown: Bool) {
        let id = volume.stableIdentifier
        let name = volume.metadata.volumeName
        guard !scanning.contains(id) else { return }

        do {
            let known = try store.drive(volumeUUID: id) != nil
            // Capacity comes from the mounted volume rather than the scan, so it's
            // current on every connect without walking anything.
            let capacity = try? volume.url.resourceValues(forKeys: [
                .volumeCreationDateKey, .volumeAvailableCapacityKey,
            ])

            let drive = try store.recordSighting(
                volumeUUID: id,
                name: name,
                mediaName: volume.metadata.mediaName,
                busProtocol: volume.metadata.busProtocol,
                isSolidStateDetected: volume.metadata.isSolidState,
                totalBytes: volume.metadata.totalBytes,
                freeBytes: capacity?.volumeAvailableCapacity.map(Int64.init),
                volumeCreatedAt: capacity?.volumeCreationDate
            )
            onActivity?(.driveConnected(name: name, alreadyKnown: known))

            guard !known || rescanKnown, let driveId = drive.id else { return }
            startScan(driveId: driveId, volume: volume, id: id, name: name)
        } catch {
            onActivity?(.scanFailed(name: name, error: "\(error)"))
        }
    }

    private func startScan(driveId: Int64, volume: MountedVolume, id: String, name: String) {
        scanning.insert(id)
        onActivity?(.scanStarted(name: name))

        // Detached so the walk doesn't block the main actor — the UI keeps serving
        // the cached tree from SQLite while this runs.
        Task.detached { [scanner, weak self] in
            do {
                let summary = try await scanner.scan(
                    volumeURL: volume.url, driveId: driveId, rootName: name
                ) { progress in
                    Task { @MainActor in
                        self?.onActivity?(.scanProgress(
                            name: name,
                            foldersScanned: progress.foldersScanned,
                            currentPath: progress.currentPath
                        ))
                    }
                }
                await MainActor.run {
                    self?.scanning.remove(id)
                    self?.onActivity?(.scanFinished(name: name, summary: summary))
                }
            } catch {
                await MainActor.run {
                    self?.scanning.remove(id)
                    self?.onActivity?(.scanFailed(name: name, error: "\(error)"))
                }
            }
        }
    }
}
