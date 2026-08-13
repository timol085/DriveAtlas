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
        /// The live watcher saw this mounted drive's contents change; its catalog
        /// is now stale.
        case driveChanged(name: String)
    }

    public let store: Store
    private let scanner: Scanner
    private var watcher: VolumeWatcher?
    private var onActivity: ((Activity) -> Void)?

    /// Drives currently being scanned, so a duplicate mount notification doesn't
    /// start a second concurrent walk of the same volume.
    private var scanning: Set<String> = []

    /// One live FSEvents watcher per mounted, catalogued drive, keyed by volume
    /// identifier. Started on connect, stopped on disconnect.
    private var changeWatchers: [String: DriveChangeWatcher] = [:]
    /// Mount path → volume identifier, so an unmount (which only gives a path)
    /// can find and stop the right watcher.
    private var watchedPathToUUID: [String: String] = [:]

    /// Pending debounced auto-rescans, keyed by volume identifier. Each detected
    /// change cancels and reschedules the drive's task, so a rescan fires only
    /// once activity has settled — not mid-import, and not once per file.
    private var pendingRescans: [String: Task<Void, Never>] = [:]

    /// How long a drive must be quiet (no further changes) before its automatic
    /// rescan fires. Long enough that sustained work — a big paste, editing in
    /// place — coalesces into one scan instead of thrashing; short enough to feel
    /// automatic. Injectable so tests can use a tiny interval.
    private let autoRescanQuietPeriod: Duration

    /// What a settled quiet-period actually does. Defaults to a real rescan;
    /// overridable so the debounce/coalesce behaviour is testable without a
    /// mounted volume.
    var autoRescanAction: ((String) -> Void)?

    public init(store: Store, autoRescanQuietPeriod: Duration = .seconds(45)) {
        self.store = store
        self.scanner = Scanner(store: store)
        self.autoRescanQuietPeriod = autoRescanQuietPeriod
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
                self.stopChangeWatcher(forPath: url.path)
                onActivity(.driveDisconnected(path: url.path))
            }
        }
        self.watcher = watcher
        watcher.start()
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        for w in changeWatchers.values { w.stop() }
        changeWatchers.removeAll()
        for t in pendingRescans.values { t.cancel() }
        pendingRescans.removeAll()
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

            // Begin watching this mounted drive for content changes. Starting
            // (or restarting) here is idempotent and covers reconnects.
            startChangeWatcher(volumeUUID: id, volumePath: volume.url.path, name: name)

            guard !known || rescanKnown, let driveId = drive.id else { return }
            startScan(driveId: driveId, volume: volume, id: id, name: name)
        } catch {
            onActivity?(.scanFailed(name: name, error: "\(error)"))
        }
    }

    // MARK: - Live change watching

    private func startChangeWatcher(volumeUUID: String, volumePath: String, name: String) {
        changeWatchers[volumeUUID]?.stop()
        let watcher = DriveChangeWatcher(volumePath: volumePath) { [weak self] in
            // FSEvents delivers on a background queue; hop to the main actor.
            Task { @MainActor in
                self?.handleContentChange(volumeUUID: volumeUUID, name: name)
            }
        }
        changeWatchers[volumeUUID] = watcher
        watchedPathToUUID[volumePath] = volumeUUID
        watcher.start()
    }

    private func stopChangeWatcher(forPath path: String) {
        guard let uuid = watchedPathToUUID.removeValue(forKey: path) else { return }
        changeWatchers.removeValue(forKey: uuid)?.stop()
        // Drop any pending auto-rescan: the drive is gone. The persisted badge
        // survives the unplug and reminds the user it never got rescanned.
        pendingRescans.removeValue(forKey: uuid)?.cancel()
    }

    private func handleContentChange(volumeUUID: String, name: String) {
        // A scan already running will end clean, so don't flag mid-scan.
        guard !scanning.contains(volumeUUID) else { return }
        // Show the badge right away — it's the fallback for the case the drive is
        // unplugged before the debounced rescan below ever gets to run.
        try? store.markNeedsRescan(volumeUUID: volumeUUID)
        onActivity?(.driveChanged(name: name))
        scheduleAutoRescan(volumeUUID: volumeUUID)
    }

    /// (Re)arms the quiet-period timer for a drive. Called on every detected
    /// change, so a burst of changes collapses to a single rescan once things go
    /// quiet. Internal for testing; not part of the public surface.
    func scheduleAutoRescan(volumeUUID: String) {
        pendingRescans[volumeUUID]?.cancel()
        pendingRescans[volumeUUID] = Task { [weak self, autoRescanQuietPeriod] in
            try? await Task.sleep(for: autoRescanQuietPeriod)
            guard !Task.isCancelled, let self else { return }
            self.pendingRescans[volumeUUID] = nil
            // rescan() no-ops if the drive was unplugged or is already scanning,
            // and the scan itself clears the persisted flag on completion.
            if let action = self.autoRescanAction {
                action(volumeUUID)
            } else {
                self.rescan(volumeUUID: volumeUUID)
            }
        }
    }

    private func startScan(driveId: Int64, volume: MountedVolume, id: String, name: String) {
        scanning.insert(id)
        // A scan is now covering this volume — any queued debounce is redundant.
        pendingRescans.removeValue(forKey: id)?.cancel()
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
