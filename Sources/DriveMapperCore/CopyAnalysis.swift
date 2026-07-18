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

    public init(atRisk: [Group], duplicated: [Group]) {
        self.atRisk = atRisk
        self.duplicated = duplicated
    }

    public var atRiskBytes: Int64 { atRisk.reduce(0) { $0 + $1.representativeBytes } }
    public var reclaimableBytes: Int64 { duplicated.reduce(0) { $0 + $1.reclaimableBytes } }
}

extension Store {

    /// Compares folders across every catalogued drive.
    ///
    /// - Parameters:
    ///   - minBytes: Folders smaller than this are ignored. Without a floor the
    ///     result is thousands of tiny folders and no signal at all.
    ///   - tolerance: How much two folders' sizes may differ and still count as
    ///     copies. Copies are rarely byte-identical — a stray `.DS_Store`, a
    ///     different filesystem, a partially-completed transfer.
    public func analyseCopies(
        minBytes: Int64 = 100_000_000,
        tolerance: Double = 0.05
    ) throws -> CopyAnalysis {

        let locations: [CopyAnalysis.Location] = try dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT folder.id      AS folderId,
                       folder.driveId AS driveId,
                       folder.name    AS name,
                       folder.path    AS path,
                       folder.totalBytes,
                       folder.totalFileCount,
                       drive.name     AS driveName
                FROM folder
                JOIN drive ON drive.id = folder.driveId
                WHERE folder.totalBytes >= ?
                  AND folder.path <> ''
                ORDER BY folder.totalBytes DESC
                """, arguments: [minBytes])
                .map {
                    CopyAnalysis.Location(
                        driveId: $0["driveId"],
                        driveName: $0["driveName"],
                        folderId: $0["folderId"],
                        path: $0["path"],
                        totalBytes: $0["totalBytes"],
                        totalFileCount: $0["totalFileCount"]
                    )
                }
        }
        // `path <> ''` above excludes drive roots — every drive has exactly one,
        // and reporting "your drive exists on only one drive" helps nobody.

        // Group by name, then split each name group into size clusters. Name alone
        // would merge every "Photos" on every drive regardless of contents;
        // size alone would merge unrelated folders that happen to weigh the same.
        var byName: [String: [CopyAnalysis.Location]] = [:]
        for location in locations {
            let key = URL(fileURLWithPath: location.path).lastPathComponent.lowercased()
            byName[key, default: []].append(location)
        }

        var groups: [CopyAnalysis.Group] = []
        for (_, sameName) in byName {
            for cluster in clusterBySize(sameName, tolerance: tolerance) {
                guard let first = cluster.first else { continue }
                let displayName = URL(fileURLWithPath: first.path).lastPathComponent
                groups.append(CopyAnalysis.Group(name: displayName, locations: cluster))
            }
        }

        let single = groups.filter { $0.driveCount == 1 }
        let multiple = groups.filter { $0.driveCount > 1 }

        return CopyAnalysis(
            atRisk: suppressDescendants(of: single)
                .sorted { $0.representativeBytes > $1.representativeBytes },
            duplicated: multiple
                .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        )
    }

    /// Splits folders sharing a name into clusters of similar size.
    ///
    /// Greedy over a descending sort: each folder joins the open cluster if it's
    /// within tolerance of that cluster's largest member, otherwise it starts a
    /// new one.
    private func clusterBySize(
        _ locations: [CopyAnalysis.Location],
        tolerance: Double
    ) -> [[CopyAnalysis.Location]] {
        let sorted = locations.sorted { $0.totalBytes > $1.totalBytes }
        var clusters: [[CopyAnalysis.Location]] = []

        for location in sorted {
            if let index = clusters.indices.last,
               let anchor = clusters[index].first?.totalBytes,
               anchor > 0,
               Double(anchor - location.totalBytes) / Double(anchor) <= tolerance {
                clusters[index].append(location)
            } else {
                clusters.append([location])
            }
        }
        return clusters
    }

    /// Drops at-risk folders whose ancestor is already listed.
    ///
    /// If `Photos` has no second copy then neither does `Photos/2019`, and listing
    /// both buries the useful row under its own children. Only the shallowest
    /// un-backed-up folder in any chain is reported.
    private func suppressDescendants(of groups: [CopyAnalysis.Group]) -> [CopyAnalysis.Group] {
        // Shallowest first, so an ancestor is always considered before its children.
        let ordered = groups.sorted {
            ($0.locations.first?.path.count ?? 0) < ($1.locations.first?.path.count ?? 0)
        }

        var keptPathsByDrive: [Int64: [String]] = [:]
        var kept: [CopyAnalysis.Group] = []

        for group in ordered {
            guard let location = group.locations.first else { continue }
            let ancestors = keptPathsByDrive[location.driveId] ?? []
            let covered = ancestors.contains { location.path.hasPrefix($0 + "/") }
            guard !covered else { continue }

            kept.append(group)
            keptPathsByDrive[location.driveId, default: []].append(location.path)
        }
        return kept
    }
}
