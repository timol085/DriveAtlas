import Foundation
import GRDB

/// Finds folders that exist on more than one drive, and folders that don't.
///
/// The question this answers is "is this backed up anywhere?" — which for a pile
/// of external drives is usually more pressing than "where is it?".
///
/// **This matches on folder name and size, not content.** Two folders called
/// "Wedding RAWs" of about the same size are *probably* the same thing, but
/// nothing here reads a single byte of file data. Treat a match as "worth
/// checking", never as a verified backup.
public struct CopyAnalysis: Sendable {

    /// One folder on one drive.
    public struct Location: Sendable, Hashable, Identifiable {
        public let driveId: Int64
        public let driveName: String
        public let folderId: Int64
        public let path: String
        public let totalBytes: Int64
        public let totalFileCount: Int

        public var id: Int64 { folderId }
    }

    /// A set of folders across drives that look like copies of each other.
    public struct Group: Sendable, Identifiable {
        public let name: String
        public let locations: [Location]
        /// Weakest pairwise file-overlap in the group (0–1). `nil` for at-risk
        /// groups (a single folder has nothing to overlap with). 1.0 for a set
        /// of byte-identical folders.
        public let overlap: Double?

        public init(name: String, locations: [Location], overlap: Double? = nil) {
            self.name = name
            self.locations = locations
            self.overlap = overlap
        }

        public var id: String { "\(name.lowercased())-\(locations.first?.folderId ?? 0)" }

        /// Distinct drives holding a copy. Two copies on the *same* drive are not
        /// a backup, so this is what the at-risk test uses — not `locations.count`.
        public var driveCount: Int {
            Set(locations.map(\.driveId)).count
        }

        public var representativeBytes: Int64 {
            locations.map(\.totalBytes).max() ?? 0
        }

        /// Space recoverable by keeping one copy and deleting the rest.
        public var reclaimableBytes: Int64 {
            let sorted = locations.map(\.totalBytes).sorted(by: >)
            return sorted.dropFirst().reduce(0, +)
        }

        public var driveNames: [String] {
            var seen = Set<Int64>()
            return locations.compactMap { location in
                seen.insert(location.driveId).inserted ? location.driveName : nil
            }
        }
    }

    /// Folders found on exactly one drive, biggest first.
    public let atRisk: [Group]
    /// Folders found on two or more drives, most reclaimable space first.
    public let duplicated: [Group]

    /// Drive names catalogued before file fingerprints existed (schema v5).
    /// They can't participate in content matching until rescanned — and an
    /// empty result for them is *missing data*, not a clean bill of health, so
    /// the UI must prompt a rescan rather than imply everything is backed up.
    public let drivesNeedingRescan: [String]

    public init(atRisk: [Group], duplicated: [Group], drivesNeedingRescan: [String] = []) {
        self.atRisk = atRisk
        self.duplicated = duplicated
        self.drivesNeedingRescan = drivesNeedingRescan
    }

    public var atRiskBytes: Int64 { atRisk.reduce(0) { $0 + $1.representativeBytes } }
    public var reclaimableBytes: Int64 { duplicated.reduce(0) { $0 + $1.reclaimableBytes } }

    /// How a Backup Check list is ordered.
    ///
    /// Logic lives here, in Core, so it's unit-testable — the view supplies only
    /// the labels and icons. Ties always break on name, so a given field +
    /// direction produces one stable order rather than a shuffling one.
    public enum SortField: String, CaseIterable, Sendable {
        case size, name, drive, reclaimable, copies

        /// Fields that make sense per list. A single-copy group has nothing to
        /// reclaim and always spans one drive, so those are hidden on the
        /// at-risk list; a duplicated group spans several, so "drive" is hidden
        /// there.
        public static func fields(duplicated: Bool) -> [SortField] {
            duplicated ? [.reclaimable, .size, .copies, .name] : [.size, .name, .drive]
        }

        /// Descending is the natural default for the quantitative fields
        /// (biggest / most first); name and drive read naturally ascending.
        public var defaultsDescending: Bool {
            switch self {
            case .size, .reclaimable, .copies: true
            case .name, .drive: false
            }
        }

        public func compare(_ a: Group, _ b: Group, ascending: Bool) -> Bool {
            func dir(_ result: Bool) -> Bool { ascending ? result : !result }
            func byName() -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }

            switch self {
            case .name:
                return dir(byName())
            case .drive:
                let da = a.locations.first?.driveName ?? ""
                let db = b.locations.first?.driveName ?? ""
                if da == db { return byName() }
                return dir(da.localizedStandardCompare(db) == .orderedAscending)
            case .size:
                if a.representativeBytes == b.representativeBytes { return byName() }
                return dir(a.representativeBytes < b.representativeBytes)
            case .reclaimable:
                if a.reclaimableBytes == b.reclaimableBytes { return byName() }
                return dir(a.reclaimableBytes < b.reclaimableBytes)
            case .copies:
                if a.driveCount == b.driveCount { return byName() }
                return dir(a.driveCount < b.driveCount)
            }
        }
    }
}

public extension Array where Element == CopyAnalysis.Group {
    /// Sorted copy, with the field's tie-break already built in.
    func sorted(by field: CopyAnalysis.SortField, ascending: Bool) -> [CopyAnalysis.Group] {
        sorted { field.compare($0, $1, ascending: ascending) }
    }
}

extension Store {

    /// Compares folders across every catalogued drive by their **file content**,
    /// not their names — so a folder backed up under a different name is still
    /// found, and two identically-named folders holding different files are not
    /// mistaken for copies.
    ///
    /// See `FolderMatcher` for the algorithm and `FilePrint` for what "content"
    /// means here (name + size fingerprints, never file bytes). The read-only
    /// guarantee holds: nothing below opens a file.
    ///
    /// - Parameter minBytes: folders smaller than this are ignored — without a
    ///   floor the result is thousands of tiny folders and no signal.
    public func analyseCopies(minBytes: Int64 = 100_000_000) throws -> CopyAnalysis {
        struct Row2 {
            let id: Int64
            let driveId: Int64
            let driveName: String
            let contentScanned: Bool
            let parentId: Int64?
            let depth: Int
            let name: String
            let path: String
            let totalBytes: Int64
            let totalFileCount: Int
            let prints: Set<UInt64>
        }

        // Every folder (roots included, for correct rollup) with its own prints.
        let rows: [Row2] = try dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT folder.id, folder.driveId, folder.parentId, folder.depth,
                       folder.name, folder.path, folder.totalBytes,
                       folder.totalFileCount, folder.filePrints,
                       drive.name AS driveName, drive.contentScanned
                FROM folder
                JOIN drive ON drive.id = folder.driveId
                """)
                .map {
                    Row2(
                        id: $0["id"], driveId: $0["driveId"], driveName: $0["driveName"],
                        contentScanned: $0["contentScanned"],
                        parentId: $0["parentId"], depth: $0["depth"],
                        name: $0["name"], path: $0["path"],
                        totalBytes: $0["totalBytes"], totalFileCount: $0["totalFileCount"],
                        prints: ($0["filePrints"] as Data?).map(FilePrint.unpack) ?? []
                    )
                }
        }

        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let result = FolderMatcher.match(
            nodes: rows.map {
                FolderMatcher.Node(
                    id: $0.id, driveId: $0.driveId, parentId: $0.parentId,
                    depth: $0.depth, totalBytes: $0.totalBytes, ownPrints: $0.prints
                )
            },
            minBytes: minBytes
        )

        func location(_ id: Int64) -> CopyAnalysis.Location? {
            guard let r = byId[id] else { return nil }
            return CopyAnalysis.Location(
                driveId: r.driveId, driveName: r.driveName, folderId: r.id,
                path: r.path, totalBytes: r.totalBytes, totalFileCount: r.totalFileCount
            )
        }

        // A duplicated group's headline name is its largest member's — folders
        // in a content match may be named differently, and each Location shows
        // its own path/drive, so the difference is still visible per row.
        let duplicated: [CopyAnalysis.Group] = result.duplicated.compactMap { cluster in
            let locs = cluster.folderIds.compactMap(location).sorted { $0.totalBytes > $1.totalBytes }
            guard locs.count >= 2 else { return nil }
            let headline = byId[locs[0].folderId]?.name ?? locs[0].path
            return CopyAnalysis.Group(name: headline, locations: locs, overlap: cluster.overlap)
        }
        .sorted { $0.reclaimableBytes > $1.reclaimableBytes }

        let atRisk: [CopyAnalysis.Group] = result.atRisk.compactMap { id -> CopyAnalysis.Group? in
            guard let loc = location(id), let name = byId[id]?.name else { return nil }
            return CopyAnalysis.Group(name: name, locations: [loc])
        }
        .sorted { $0.representativeBytes > $1.representativeBytes }

        // A drive needs rescanning if it was scanned before fingerprinting
        // existed (`contentScanned == false`) yet holds real content. Uses the
        // drive-level flag, not per-folder print presence: leaf bundles and
        // folders whose files are all nested legitimately have no own-prints, so
        // a "folder with files but no prints" check flagged fully-scanned drives
        // forever.
        var needRescan = Set<String>()
        for row in rows where !row.contentScanned
            && row.parentId != nil
            && row.totalBytes >= minBytes
            && row.totalFileCount > 0 {
            needRescan.insert(row.driveName)
        }

        return CopyAnalysis(
            atRisk: atRisk, duplicated: duplicated,
            drivesNeedingRescan: needRescan.sorted()
        )
    }
}
