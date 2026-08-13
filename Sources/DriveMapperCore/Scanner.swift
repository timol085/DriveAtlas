import Foundation
import GRDB

/// Walks a mounted volume and records its folder structure.
///
/// Runs as an actor so a scan stays off the main thread; the UI reads the
/// previously cached tree from the `Store` while this writes. SQLite is in WAL
/// mode, so readers are never blocked by the scan's writes.
///
/// The walk is post-order: a folder's row is inserted on the way down (to get an
/// id for its children to reference) and updated with rollup totals on the way
/// back up. Accumulating rollups during the walk is the whole reason for doing it
/// this way — computing them afterwards would mean a second full pass.
public actor Scanner {

    /// A scan that must not commit.
    ///
    /// Thrown from inside the write transaction, so GRDB rolls the whole thing
    /// back and the drive's previous catalogue survives untouched. Without this,
    /// unplugging a drive mid-scan silently committed a nearly-empty tree over
    /// good data — every directory read failed, each recorded as an empty folder.
    public enum ScanError: LocalizedError {
        case rootUnreadable(String)
        case volumeVanished(String)

        public var errorDescription: String? {
            switch self {
            case .rootUnreadable(let path):
                "Couldn't read \(path) — the previous catalogue was kept."
            case .volumeVanished(let path):
                "The drive at \(path) disconnected during the scan — the previous catalogue was kept."
            }
        }
    }

    public struct Options: Sendable {
        /// Safety valve against symlink loops and pathological nesting. Real trees
        /// are nowhere near this deep.
        public var maxDepth: Int
        /// Directories recorded as a single node without descending or sizing.
        /// Build artefacts and system noise — you'd never search for what's inside.
        public var skipEntirely: Set<String>
        /// How many rollup extensions to keep per folder. The hover popover shows a
        /// handful; storing every extension for every folder would balloon the table
        /// into the millions of rows on a large drive.
        public var maxRollupExtensions: Int

        public init(
            maxDepth: Int = 64,
            skipEntirely: Set<String> = [
                "node_modules", ".git", ".Trashes", ".Spotlight-V100",
                ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
                ".DS_Store", "System Volume Information", "$RECYCLE.BIN",
            ],
            maxRollupExtensions: Int = 20
        ) {
            self.maxDepth = maxDepth
            self.skipEntirely = skipEntirely
            self.maxRollupExtensions = maxRollupExtensions
        }
    }

    public struct Progress: Sendable {
        public var foldersScanned: Int
        public var currentPath: String
    }

    public struct Summary: Sendable {
        public var folderCount: Int
        public var fileCount: Int
        public var totalBytes: Int64
        public var duration: TimeInterval
    }

    /// Aggregated facts about one subtree, carried back up the recursion.
    private struct Aggregate {
        var totalBytes: Int64 = 0
        var fileCount: Int = 0
        /// ext -> (count, bytes), including every descendant.
        var extensions: [String: (count: Int, bytes: Int64)] = [:]

        mutating func absorb(_ other: Aggregate) {
            totalBytes += other.totalBytes
            fileCount += other.fileCount
            for (ext, stat) in other.extensions {
                let existing = extensions[ext] ?? (0, 0)
                extensions[ext] = (existing.count + stat.count, existing.bytes + stat.bytes)
            }
        }
    }

    private let store: Store
    private let options: Options

    public init(store: Store, options: Options = Options()) {
        self.store = store
        self.options = options
    }

    /// Scans `volumeURL` and replaces any previously stored tree for `driveId`.
    ///
    /// This is a full rewrite: every folder row for the drive is deleted and
    /// rebuilt. Skipping redundant writes via stored mtimes is a later refinement
    /// — note that it can only ever avoid *writes*, never traversal, because macOS
    /// does not propagate directory mtimes up the tree.
    @discardableResult
    public func scan(
        volumeURL: URL,
        driveId: Int64,
        rootName: String? = nil,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) throws -> Summary {
        let started = Date()
        var foldersScanned = 0

        let summary = try store.dbWriter.write { db -> Summary in
            // Full rewrite. Cascades to folder_ext and the FTS index.
            try Folder.filter(Folder.Columns.driveId == driveId).deleteAll(db)

            let name = rootName ?? volumeURL.lastPathComponent
            let aggregate = try self.walk(
                db: db,
                url: volumeURL,
                driveId: driveId,
                parentId: nil,
                name: name,
                relativePath: "",
                depth: 0,
                foldersScanned: &foldersScanned,
                onProgress: onProgress
            )

            // The volume must still be there before this commits. If it was
            // unplugged mid-walk, every read below the unplug point failed
            // silently and the "tree" we just built is a husk — throwing here
            // rolls the transaction back instead of destroying the catalogue.
            guard (try? volumeURL.checkResourceIsReachable()) == true else {
                throw ScanError.volumeVanished(volumeURL.path)
            }

            return Summary(
                folderCount: foldersScanned,
                fileCount: aggregate.fileCount,
                totalBytes: aggregate.totalBytes,
                duration: Date().timeIntervalSince(started)
            )
        }

        try store.dbWriter.write { db in
            // `contentScanned` marks that this scan wrote file fingerprints, so
            // Backup Check knows the drive can be content-matched — see the v6
            // migration note for why folder-print presence isn't a reliable
            // per-drive signal.
            try db.execute(
                sql: "UPDATE drive SET lastScannedAt = ?, contentScanned = 1, needsRescan = 0 WHERE id = ?",
                arguments: [Date(), driveId]
            )
        }

        return summary
    }

    // MARK: - Walk

    private func walk(
        db: Database,
        url: URL,
        driveId: Int64,
        parentId: Int64?,
        name: String,
        relativePath: String,
        depth: Int,
        foldersScanned: inout Int,
        onProgress: (@Sendable (Progress) -> Void)?
    ) throws -> Aggregate {

        let attrs = try? url.resourceValues(forKeys: [
            .contentModificationDateKey, .creationDateKey,
        ])

        // Insert on the way down so children have a parent id to reference.
        var folder = Folder(
            driveId: driveId,
            parentId: parentId,
            name: name,
            path: relativePath,
            depth: depth,
            mtime: attrs?.contentModificationDate,
            createdAt: attrs?.creationDate
        )
        try folder.insert(db)
        let folderId = folder.id!

        foldersScanned += 1
        onProgress?(Progress(foldersScanned: foldersScanned, currentPath: relativePath))

        var aggregate = Aggregate()
        /// Files directly in this folder, kept separate so the hover can distinguish
        /// "files here" from "files anywhere below here".
        var ownExtensions: [String: (count: Int, bytes: Int64)] = [:]
        var ownBytes: Int64 = 0
        var ownFileCount = 0
        /// Fingerprints of files directly in this folder, for content matching.
        var ownPrints = Set<UInt64>()

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        ]

        // An unreadable directory deep in the tree (permissions, I/O error) is
        // recorded as an empty node rather than failing the whole scan — one bad
        // folder shouldn't cost you a multi-minute walk. The ROOT is different:
        // if the volume itself can't be read there is no scan, only the illusion
        // of an empty drive, so that aborts (and rolls back) instead.
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            if depth == 0 { throw ScanError.rootUnreadable(url.path) }
            entries = []
        }

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }

            // Never follow symlinks — they're the main way a walk turns infinite.
            if values.isSymbolicLink == true { continue }

            if values.isDirectory == true {
                let childName = entry.lastPathComponent
                let childPath = relativePath.isEmpty ? childName : "\(relativePath)/\(childName)"

                if options.skipEntirely.contains(childName) {
                    // Recorded so you can see it exists, but not descended into and
                    // not sized — walking node_modules to measure it is exactly the
                    // cost we're avoiding.
                    var leaf = Folder(
                        driveId: driveId, parentId: folderId, name: childName,
                        path: childPath, depth: depth + 1,
                        isLeafBundle: true,
                        mtime: values.contentModificationDate,
                        createdAt: values.creationDate
                    )
                    try leaf.insert(db)
                    foldersScanned += 1
                    continue
                }

                if values.isPackage == true {
                    // A package (.photoslibrary, .app) is user-facing data worth
                    // sizing, so we do measure it — just without recording its
                    // internals as browsable folders.
                    let size = Self.flatSize(of: entry)
                    var leaf = Folder(
                        driveId: driveId, parentId: folderId, name: childName,
                        path: childPath, depth: depth + 1,
                        ownBytes: size.bytes, totalBytes: size.bytes,
                        ownFileCount: size.files, totalFileCount: size.files,
                        isLeafBundle: true,
                        mtime: values.contentModificationDate,
                        createdAt: values.creationDate
                    )
                    try leaf.insert(db)
                    foldersScanned += 1

                    aggregate.totalBytes += size.bytes
                    aggregate.fileCount += size.files
                    let ext = entry.pathExtension.lowercased()
                    let prior = aggregate.extensions[ext] ?? (0, 0)
                    aggregate.extensions[ext] = (prior.count + 1, prior.bytes + size.bytes)
                    continue
                }

                guard depth + 1 <= options.maxDepth else { continue }

                let child = try walk(
                    db: db, url: entry, driveId: driveId, parentId: folderId,
                    name: childName, relativePath: childPath, depth: depth + 1,
                    foldersScanned: &foldersScanned, onProgress: onProgress
                )
                aggregate.absorb(child)
            } else {
                let bytes = Int64(values.fileSize ?? 0)
                let ext = entry.pathExtension.lowercased()

                ownBytes += bytes
                ownFileCount += 1
                ownPrints.insert(FilePrint.of(name: entry.lastPathComponent, size: bytes))
                let priorOwn = ownExtensions[ext] ?? (0, 0)
                ownExtensions[ext] = (priorOwn.count + 1, priorOwn.bytes + bytes)

                aggregate.totalBytes += bytes
                aggregate.fileCount += 1
                let prior = aggregate.extensions[ext] ?? (0, 0)
                aggregate.extensions[ext] = (prior.count + 1, prior.bytes + bytes)
            }
        }

        // On the way back up: write the totals we could only know now, plus the
        // packed file fingerprints for this folder's own files.
        let printsBlob = ownPrints.isEmpty ? nil : FilePrint.pack(ownPrints)
        try db.execute(sql: """
            UPDATE folder
            SET ownBytes = ?, totalBytes = ?, ownFileCount = ?, totalFileCount = ?, filePrints = ?
            WHERE id = ?
            """, arguments: [ownBytes, aggregate.totalBytes, ownFileCount, aggregate.fileCount, printsBlob, folderId])

        try writeExtensions(
            db: db, folderId: folderId, own: ownExtensions, rollup: aggregate.extensions
        )

        return aggregate
    }

    /// Merges own and rollup extension stats into one row per extension.
    private func writeExtensions(
        db: Database,
        folderId: Int64,
        own: [String: (count: Int, bytes: Int64)],
        rollup: [String: (count: Int, bytes: Int64)]
    ) throws {
        // Keep the biggest rollup extensions, plus anything present directly in this
        // folder (those are few, and dropping them would make the "own" view lie).
        let topRollup = rollup
            .sorted { $0.value.bytes > $1.value.bytes }
            .prefix(options.maxRollupExtensions)
        var keep = Set(topRollup.map(\.key))
        keep.formUnion(own.keys)

        for ext in keep {
            let o = own[ext] ?? (0, 0)
            let r = rollup[ext] ?? (0, 0)
            try FolderExtension(
                folderId: folderId, ext: ext,
                ownCount: o.count, ownBytes: o.bytes,
                rollCount: r.count, rollBytes: r.bytes
            ).insert(db)
        }
    }

    /// Total size of a package's contents, without recording its internals.
    private static func flatSize(of url: URL) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        )
        while let child = enumerator?.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }
}
