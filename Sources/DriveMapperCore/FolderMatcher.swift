import Foundation

/// Finds folders that hold the same *files* across drives — even when the
/// folders are named differently — by comparing their file-fingerprint sets.
///
/// This is what makes Backup Check catch "Japan" on one drive and "JP trip" on
/// another as the same backup. It compares whole-folder overlap, never single
/// files, which is deliberately robust to a camera reusing `001.arw` for
/// different photos: one coincidental fingerprint collision among hundreds of
/// files barely moves a folder's overlap score.
///
/// Pure and store-free so the algorithm is unit-testable on plain fixtures.
public enum FolderMatcher {

    public struct Node: Sendable {
        public let id: Int64
        public let driveId: Int64
        public let parentId: Int64?
        public let depth: Int
        public let totalBytes: Int64
        /// Fingerprints of files **directly** in this folder. Descendants roll
        /// up during matching.
        public let ownPrints: Set<UInt64>

        public init(
            id: Int64, driveId: Int64, parentId: Int64?, depth: Int,
            totalBytes: Int64, ownPrints: Set<UInt64>
        ) {
            self.id = id
            self.driveId = driveId
            self.parentId = parentId
            self.depth = depth
            self.totalBytes = totalBytes
            self.ownPrints = ownPrints
        }
    }

    public struct Cluster: Sendable {
        /// Folder ids that hold the same content, across ≥ 2 distinct drives.
        public let folderIds: [Int64]
        /// Lowest pairwise overlap in the cluster (0–1) — the honest figure to
        /// show, since it's the weakest link in "these are all copies".
        public let overlap: Double
    }

    public struct Result: Sendable {
        /// Folders whose content is replicated on another drive.
        public let duplicated: [Cluster]
        /// Folders with no content match on any other drive.
        public let atRisk: [Int64]
    }

    /// - Parameters:
    ///   - minBytes: ignore folders smaller than this — the same floor the rest
    ///     of Backup Check uses.
    ///   - threshold: minimum Jaccard overlap (|A∩B| / |A∪B|) to call two
    ///     folders copies. 0.80 tolerates a handful of added/stray files.
    ///   - sizeTolerance: only bother comparing folders whose total sizes are
    ///     within this fraction — the pruning that keeps it from being O(n²)
    ///     across the whole catalogue.
    public static func match(
        nodes: [Node],
        minBytes: Int64,
        threshold: Double = 0.80,
        sizeTolerance: Double = 0.35
    ) -> Result {
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var children: [Int64: [Int64]] = [:]
        for node in nodes where node.parentId != nil {
            children[node.parentId!, default: []].append(node.id)
        }

        // Rollup prints = own ∪ every descendant's, computed once per folder.
        var rollup: [Int64: Set<UInt64>] = [:]
        func buildRollup(_ id: Int64) -> Set<UInt64> {
            if let cached = rollup[id] { return cached }
            var set = byId[id]?.ownPrints ?? []
            for child in children[id] ?? [] {
                set.formUnion(buildRollup(child))
            }
            rollup[id] = set
            return set
        }
        for node in nodes { _ = buildRollup(node.id) }

        // Candidates: big enough, has content, and not a drive root (roots have
        // no parent) — "your whole drive exists on one drive" helps no one.
        let candidates = nodes.filter {
            $0.parentId != nil && $0.totalBytes >= minBytes && !(rollup[$0.id]?.isEmpty ?? true)
        }.sorted { $0.totalBytes < $1.totalBytes }

        // Similar cross-drive pairs, pruned by a size window so we never compare
        // a 2 GB folder against a 400 GB one.
        struct Edge { let a: Int64; let b: Int64; let overlap: Double }
        var edges: [Edge] = []
        for i in candidates.indices {
            let a = candidates[i]
            let aPrints = rollup[a.id]!
            let sizeCeiling = Double(a.totalBytes) * (1 + sizeTolerance)
            var j = i + 1
            while j < candidates.count, Double(candidates[j].totalBytes) <= sizeCeiling {
                let b = candidates[j]
                defer { j += 1 }
                guard a.driveId != b.driveId else { continue }
                let overlap = jaccard(aPrints, rollup[b.id]!)
                if overlap >= threshold {
                    edges.append(Edge(a: a.id, b: b.id, overlap: overlap))
                }
            }
        }

        // Union-find over the edges → clusters.
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var root = x
            while let p = parent[root], p != root { root = p }
            var cur = x
            while let p = parent[cur], p != root { parent[cur] = root; cur = p }
            return root
        }
        func union(_ x: Int64, _ y: Int64) {
            parent[x] = parent[x] ?? x
            parent[y] = parent[y] ?? y
            parent[find(x)] = find(y)
        }
        for edge in edges { union(edge.a, edge.b) }

        var clusterMembers: [Int64: Set<Int64>] = [:]
        var clusterMinOverlap: [Int64: Double] = [:]
        for edge in edges {
            let root = find(edge.a)
            clusterMembers[root, default: []].formUnion([edge.a, edge.b])
            clusterMinOverlap[root] = min(clusterMinOverlap[root] ?? 1, edge.overlap)
        }

        // A folder is "backed up" only if its cluster spans ≥ 2 distinct drives.
        var duplicatedFolderIds = Set<Int64>()
        var rawClusters: [(members: [Int64], overlap: Double, minDepth: Int)] = []
        for (root, members) in clusterMembers {
            let drives = Set(members.compactMap { byId[$0]?.driveId })
            guard drives.count >= 2 else { continue }
            duplicatedFolderIds.formUnion(members)
            let minDepth = members.compactMap { byId[$0]?.depth }.min() ?? 0
            rawClusters.append((members.sorted(), clusterMinOverlap[root] ?? 1, minDepth))
        }

        // Descendant suppression, shared across both lists: report the
        // shallowest folder in any chain, drop its descendants. If "Japan"
        // is handled, "Japan/2019" is redundant whether it matched or not.
        func ancestorChain(_ id: Int64) -> [Int64] {
            var chain: [Int64] = []
            var current = byId[id]?.parentId
            while let c = current { chain.append(c); current = byId[c]?.parentId }
            return chain
        }

        var keptByDrive: [Int64: Set<Int64>] = [:]
        func isCovered(_ node: Node) -> Bool {
            let kept = keptByDrive[node.driveId] ?? []
            return ancestorChain(node.id).contains { kept.contains($0) }
        }
        func markKept(_ node: Node) {
            keptByDrive[node.driveId, default: []].insert(node.id)
        }

        // Shallowest first so ancestors win.
        var duplicated: [Cluster] = []
        for cluster in rawClusters.sorted(by: { $0.minDepth < $1.minDepth }) {
            let visible = cluster.members.filter { id in
                guard let node = byId[id] else { return false }
                return !isCovered(node)
            }
            guard Set(visible.compactMap { byId[$0]?.driveId }).count >= 2 else { continue }
            for id in visible { if let node = byId[id] { markKept(node) } }
            duplicated.append(Cluster(folderIds: visible, overlap: cluster.overlap))
        }

        var atRisk: [Int64] = []
        for node in candidates.sorted(by: { $0.depth < $1.depth }) {
            guard !duplicatedFolderIds.contains(node.id), !isCovered(node) else { continue }
            markKept(node)
            atRisk.append(node.id)
        }

        return Result(duplicated: duplicated, atRisk: atRisk)
    }

    static func jaccard(_ a: Set<UInt64>, _ b: Set<UInt64>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        var intersection = 0
        for value in small where large.contains(value) { intersection += 1 }
        let union = a.count + b.count - intersection
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }
}
