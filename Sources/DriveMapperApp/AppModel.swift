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
            case .scanFailed(let name, let error):
                self.scanStatus[name] = nil
                self.lastError = "\(name): \(error)"
            case .driveDisconnected:
                self.refreshDrives()
            }
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

    func forget(_ drive: Drive) {
        guard let id = drive.id else { return }
        do {
            try store.deleteDrive(id: id)
            refreshDrives()
        } catch {
            lastError = "Couldn't forget drive: \(error.localizedDescription)"
        }
    }

    // MARK: - Search

    func rerunSearch() {
        let query = searchQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        do {
            let hits = try store.searchFolders(query)
            let namesById = Dictionary(
                uniqueKeysWithValues: drives.compactMap { d in d.id.map { ($0, d.name) } }
            )
            // Which drive a hit is on is the entire point — never show a bare path.
            searchResults = hits.map {
                SearchHit(folder: $0, driveName: namesById[$0.driveId] ?? "Unknown drive")
            }
        } catch {
            lastError = "Search failed: \(error.localizedDescription)"
            searchResults = []
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
