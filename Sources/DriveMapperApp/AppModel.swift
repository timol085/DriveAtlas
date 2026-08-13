import Foundation
import Observation
import SwiftUI
import DriveMapperCore

/// Observable state backing the whole UI.
///
/// Owns the `DriveCatalog` (which owns the watcher and scanner) and exposes the
/// bits SwiftUI needs. Everything here is main-actor; the actual scanning happens
/// on a background actor inside `DriveCatalog`, and the UI reads the cached tree
/// from SQLite throughout.
@Observable
@MainActor
final class AppModel {

    private(set) var drives: [Drive] = []
    private(set) var scanStatus: [String: ScanStatus] = [:]
    private(set) var lastError: String?

    /// What the sidebar has selected. An enum rather than a bare drive id because
    /// the sidebar now also holds cross-drive views that belong to no one drive.
    enum Selection: Hashable {
        case backupCheck
        case drive(Int64)
    }

    var selection: Selection?
    var searchQuery: String = ""
    private(set) var searchResults: [SearchHit] = []

    private(set) var copyAnalysis: CopyAnalysis?
    private(set) var isAnalysing = false

    let store: Store
    private let catalog: DriveCatalog

    /// Fires after every activity event, scan-related or not. `StatusItemController`
    /// uses this to repaint the menu-bar icon without polling — kept as a plain
    /// closure rather than an @Observable property because the menu bar icon is
    /// AppKit, not SwiftUI, and has nothing to observe.
    var onActivityChanged: (() -> Void)?

    struct ScanStatus: Equatable {
        var foldersScanned: Int
        var currentPath: String
    }

    struct SearchHit: Identifiable, Equatable {
        var id: Int64 { folder.id ?? 0 }
        let folder: Folder
        let driveName: String
    }

    init() {
        // Falls back to an in-memory store so a permissions or disk problem shows
        // an empty window with an error rather than crashing on launch.
        let store: Store
        var startupError: String?
        do {
            store = try Store(url: try Store.defaultURL())
        } catch {
            startupError = "Couldn't open the catalog: \(error.localizedDescription)"
            store = try! Store()
        }
        self.store = store
        self.catalog = DriveCatalog(store: store)
        self.lastError = startupError
        refreshDrives()
    }

    func start() {
        DebugBridge.start(model: self)
        // Rebuild the system Spotlight donations once per launch — picks up
        // CLI-driven scans and heals any index drift.
        SpotlightIndexer.reindexAll(store: store)
        catalog.start { [weak self] activity in
            guard let self else { return }
            switch activity {
            case .driveConnected:
                self.refreshDrives()
            case .scanStarted(let name):
                self.scanStatus[name] = ScanStatus(foldersScanned: 0, currentPath: "")
            case .scanProgress(let name, let count, let path):
                self.scanStatus[name] = ScanStatus(foldersScanned: count, currentPath: path)
            case .scanFinished(let name, _):
                self.scanStatus[name] = nil
                self.refreshDrives()
                self.rerunSearch()
                // The copy analysis is now stale — the whole point of rescanning
                // after deleting duplicates is seeing updated numbers. Recompute
                // in place if the user is looking at it, otherwise just drop it
                // so the next visit recomputes.
                if self.selection == .backupCheck {
                    self.copyAnalysis = nil
                    self.runCopyAnalysis()
                } else {
                    self.copyAnalysis = nil
                }
                // Fresh catalog contents → fresh Spotlight donations.
                if let drive = self.drives.first(where: { $0.name == name }) {
                    SpotlightIndexer.reindex(drive: drive, store: self.store)
                }
            case .scanFailed(let name, let error):
                self.scanStatus[name] = nil
                self.lastError = "\(name): \(error)"
            case .driveDisconnected:
                self.refreshDrives()
            case .driveChanged:
                // The store's needsRescan flag is now set; reload so the sidebar
                // badge appears.
                self.refreshDrives()
            }
            self.onActivityChanged?()
        }
    }

    func stop() { catalog.stop() }

    // MARK: - Drives

    func refreshDrives() {
        do {
            drives = try store.allDrives()
            if selection == nil, let first = drives.first?.id {
                selection = .drive(first)
            }
            // Keep a selection alive if the selected drive was forgotten.
            if case .drive(let id) = selection,
               !drives.contains(where: { $0.id == id }) {
                selection = drives.first?.id.map(Selection.drive)
            }
        } catch {
            lastError = "Couldn't load drives: \(error.localizedDescription)"
        }
    }

    var selectedDrive: Drive? {
        guard case .drive(let id) = selection else { return nil }
        return drives.first { $0.id == id }
    }

    // MARK: - Backup check

    /// Runs the cross-drive comparison off the main actor.
    ///
    /// It reads every folder above the size floor across every drive, which is
    /// fast for a few thousand rows but shouldn't be assumed so — a drive with
    /// deep trees could make this take a moment, and the window must stay live.
    func runCopyAnalysis() {
        guard !isAnalysing else { return }
        isAnalysing = true

        let store = self.store
        Task.detached {
            let result = Result { try store.analyseCopies() }
            await MainActor.run {
                self.isAnalysing = false
                switch result {
                case .success(let analysis): self.copyAnalysis = analysis
                case .failure(let error):
                    self.lastError = "Backup check failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// True while a scan is running for this drive, so the UI can show that the
    /// tree it's displaying is mid-refresh.
    func scanStatus(for drive: Drive) -> ScanStatus? {
        scanStatus[drive.name]
    }

    var isScanningAnything: Bool { !scanStatus.isEmpty }

    func setSolidStateOverride(_ value: Bool?, for drive: Drive) {
        guard let id = drive.id else { return }
        do {
            try store.updateDrive(id: id, isSolidStateOverride: .some(value))
            refreshDrives()
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func setPurchaseDate(_ date: Date?, for drive: Drive) {
        guard let id = drive.id else { return }
        do {
            try store.updateDrive(id: id, purchasedOn: .some(date))
            refreshDrives()
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// On-demand rescan of a connected drive. Explains itself when the drive
    /// isn't plugged in instead of silently doing nothing.
    func rescan(_ drive: Drive) {
        guard scanStatus(for: drive) == nil else { return }
        if !catalog.rescan(volumeUUID: drive.volumeUUID) {
            lastError = "\(drive.name) isn't connected. Plug it in and it will be rescanned automatically."
        }
    }

    /// Jump to a folder from an external entry point (a Spotlight result).
    /// Selects its drive and surfaces it through search, which also shows any
    /// same-named siblings on other drives — a feature, not a shortcut.
    func reveal(folderId: Int64) {
        guard let folder = try? store.folder(id: folderId),
              let drive = drives.first(where: { $0.id == folder.driveId })
        else {
            lastError = "That folder is no longer in the catalog — it may have been rescanned away."
            return
        }
        selection = .drive(drive.id ?? -1)
        searchQuery = folder.name
        rerunSearch()
    }

    func forget(_ drive: Drive) {
        guard let id = drive.id else { return }
        do {
            try store.deleteDrive(id: id)
            SpotlightIndexer.remove(volumeUUID: drive.volumeUUID)
            refreshDrives()
            // The analysis still references the forgotten drive — drop it so the
            // next Backup Check visit recomputes. This was the last reason the
            // manual Refresh button existed.
            copyAnalysis = nil
        } catch {
            lastError = "Couldn't forget drive: \(error.localizedDescription)"
        }
    }

    // MARK: - Search

    func rerunSearch() {
        searchResults = search(searchQuery)
    }

    /// Pure search, used by both the main window's search field and the
    /// quick-search panel. Doesn't touch `searchQuery`/`searchResults` — the
    /// panel calling this must never clobber whatever the main window has on
    /// screen, and vice versa.
    func search(_ query: String) -> [SearchHit] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do {
            let hits = try store.searchFolders(query)
            let namesById = Dictionary(
                uniqueKeysWithValues: drives.compactMap { d in d.id.map { ($0, d.name) } }
            )
            // Which drive a hit is on is the entire point — never show a bare path.
            return hits.map {
                SearchHit(folder: $0, driveName: namesById[$0.driveId] ?? "Unknown drive")
            }
        } catch {
            lastError = "Search failed: \(error.localizedDescription)"
            return []
        }
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func dismissError() { lastError = nil }
}

// MARK: - Formatting

extension Drive {
    var kindLabel: String {
        switch isSolidState {
        case true: "SSD"
        case false: "HDD"
        case nil: "Unknown type"
        }
    }

    var kindSymbol: String {
        switch isSolidState {
        case true: "memorychip"
        case false: "opticaldiscdrive"
        case nil: "questionmark.circle"
        }
    }

    /// How the age reads in the UI. `nil` when there's no honest basis — better to
    /// show "Unknown" than to invent a number.
    ///
    /// The rules behind `ageBasis` live in `DriveMapperCore`, where they're
    /// covered by tests; only the wording is here.
    var ageDescription: String? {
        switch ageBasis {
        case .purchased(let date): "owned \(Self.elapsed(since: date))"
        case .formatted(let date): "formatted \(Self.elapsed(since: date)) ago"
        case .unknown: nil
        }
    }

    var showsAgeWarning: Bool { isWearRisk() }

    private static func elapsed(since date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date, to: Date())
        if let y = parts.year, y > 0 { return "\(y) year\(y == 1 ? "" : "s")" }
        if let m = parts.month, m > 0 { return "\(m) month\(m == 1 ? "" : "s")" }
        return "under a month"
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
