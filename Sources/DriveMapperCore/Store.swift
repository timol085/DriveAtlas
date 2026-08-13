import Foundation
import GRDB

/// Persistent storage for the drive catalog.
///
/// Backed by SQLite via GRDB. Uses a `DatabasePool` on disk so the UI can keep
/// reading the cached tree while a scan writes in the background — that
/// concurrency is what makes a multi-minute HDD scan tolerable.
public final class Store: Sendable {
    public let dbWriter: any DatabaseWriter

    /// Opens (and migrates) the catalog at `url`.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbWriter = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(dbWriter)
    }

    /// In-memory store for tests.
    public init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbWriter = try DatabaseQueue(configuration: config)
        try Self.migrator.migrate(dbWriter)
    }

    /// Default on-disk location: `~/Library/Application Support/DriveAtlas/catalog.sqlite`
    ///
    /// The app shipped its first catalogues under the old name, DriveMapper, so
    /// this migrates that directory once — losing the catalog on rename would
    /// mean rescanning every drive.
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let newDir = base.appending(path: "DriveAtlas")
        let oldDir = base.appending(path: "DriveMapper")
        if !FileManager.default.fileExists(atPath: newDir.path),
           FileManager.default.fileExists(atPath: oldDir.path) {
            try? FileManager.default.moveItem(at: oldDir, to: newDir)
        }
        return newDir.appending(path: "catalog.sqlite")
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "drive") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("volumeUUID", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("mediaName", .text)
                t.column("busProtocol", .text)
                t.column("isSolidStateDetected", .boolean)
                t.column("isSolidStateOverride", .boolean)
                t.column("totalBytes", .integer)
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime).notNull()
                t.column("lastScannedAt", .datetime)
                t.column("volumeCreatedAt", .datetime)
                t.column("purchasedOn", .datetime)
            }

            try db.create(table: "folder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("driveId", .integer).notNull()
                    .references("drive", onDelete: .cascade)
                t.column("parentId", .integer)
                    .references("folder", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("depth", .integer).notNull()
                t.column("ownBytes", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer).notNull().defaults(to: 0)
                t.column("ownFileCount", .integer).notNull().defaults(to: 0)
                t.column("totalFileCount", .integer).notNull().defaults(to: 0)
                t.column("isLeafBundle", .boolean).notNull().defaults(to: false)
                t.column("mtime", .datetime)
                t.column("scannedAt", .datetime).notNull()
            }
            // Rescans look folders up by (drive, path) constantly; this is the hot index.
            try db.create(
                index: "folder_on_driveId_path",
                on: "folder",
                columns: ["driveId", "path"],
                unique: true
            )
            try db.create(index: "folder_on_parentId", on: "folder", columns: ["parentId"])

            try db.create(table: "folder_ext") { t in
                t.column("folderId", .integer).notNull()
                    .references("folder", onDelete: .cascade)
                t.column("ext", .text).notNull()
                t.column("ownCount", .integer).notNull().defaults(to: 0)
                t.column("ownBytes", .integer).notNull().defaults(to: 0)
                t.column("rollCount", .integer).notNull().defaults(to: 0)
                t.column("rollBytes", .integer).notNull().defaults(to: 0)
                t.primaryKey(["folderId", "ext"])
            }
        }

        migrator.registerMigration("v2-fts") { db in
            // External-content FTS5 over folder.name. `synchronize` installs the
            // triggers that keep it in step with inserts/updates/deletes.
            try db.create(virtualTable: "folder_fts", using: FTS5()) { t in
                t.synchronize(withTable: "folder")
                t.column("name")
                t.tokenizer = .unicode61()
            }
        }

        // Added after the schema shipped, so existing catalogues carry NULL until
        // their drive is rescanned. Sorting treats NULL as unknown and pushes it
        // to the end rather than pretending it's the epoch.
        migrator.registerMigration("v3-folder-created") { db in
            try db.alter(table: "folder") { t in
                t.add(column: "createdAt", .datetime)
            }
        }

        // Free space is read off the mounted volume, not derived from the scan, so
        // this fills in the next time each drive is connected — no rescan needed.
        migrator.registerMigration("v4-free-space") { db in
            try db.alter(table: "drive") { t in
                t.add(column: "freeBytes", .integer)
            }
        }

        // Per-folder file fingerprints (packed UInt64 blob) for content-based
        // folder matching. NULL until the drive is rescanned — folders with no
        // prints simply don't participate in content matching, which degrades to
        // "not a detectable copy" rather than a wrong answer.
        migrator.registerMigration("v5-file-prints") { db in
            try db.alter(table: "folder") { t in
                t.add(column: "filePrints", .blob)
            }
        }

        // A drive-level flag for "scanned since fingerprinting existed".
        //
        // Presence of prints is NOT a reliable per-drive signal: leaf bundles
        // (`.fcpbundle`) and folders whose files are all nested in subfolders
        // legitimately have no own-prints, so a "folder with files but no
        // prints" check flagged fully-scanned drives forever. This flag is set
        // once, by the scanner, when a scan completes — unambiguous.
        //
        // Back-filled true for any drive that already has at least one
        // fingerprinted folder, so drives rescanned under v5 don't demand yet
        // another rescan.
        migrator.registerMigration("v6-content-scanned") { db in
            try db.alter(table: "drive") { t in
                t.add(column: "contentScanned", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: """
                UPDATE drive SET contentScanned = 1
                WHERE id IN (SELECT DISTINCT driveId FROM folder WHERE filePrints IS NOT NULL)
                """)
        }

        // "Catalog is stale" flag, set by the live change-watcher, cleared by a
        // scan. Persisted so it survives unplugging.
        migrator.registerMigration("v7-needs-rescan") { db in
            try db.alter(table: "drive") { t in
                t.add(column: "needsRescan", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }

    // MARK: - Drives

    /// Records that a drive was seen, creating it on first sight.
    ///
    /// Preserves `firstSeenAt` and any user-set fields (`isSolidStateOverride`,
    /// `purchasedOn`) across reconnects — only the observed hardware facts and
    /// `lastSeenAt` are refreshed.
    @discardableResult
    public func recordSighting(
        volumeUUID: String,
        name: String,
        mediaName: String? = nil,
        busProtocol: String? = nil,
        isSolidStateDetected: Bool? = nil,
        totalBytes: Int64? = nil,
        freeBytes: Int64? = nil,
        volumeCreatedAt: Date? = nil,
        now: Date = Date()
    ) throws -> Drive {
        try dbWriter.write { db in
            if var existing = try Drive
                .filter(Drive.Columns.volumeUUID == volumeUUID)
                .fetchOne(db)
            {
                existing.name = name
                existing.mediaName = mediaName
                existing.busProtocol = busProtocol
                existing.isSolidStateDetected = isSolidStateDetected
                existing.totalBytes = totalBytes
                // Only overwrite when we actually measured it — a sighting that
                // couldn't read capacity shouldn't blank out the last known value.
                if let freeBytes { existing.freeBytes = freeBytes }
                existing.volumeCreatedAt = volumeCreatedAt
                existing.lastSeenAt = now
                try existing.update(db)
                return existing
            }

            var drive = Drive(
                volumeUUID: volumeUUID,
                name: name,
                mediaName: mediaName,
                busProtocol: busProtocol,
                isSolidStateDetected: isSolidStateDetected,
                totalBytes: totalBytes,
                freeBytes: freeBytes,
                firstSeenAt: now,
                lastSeenAt: now,
                volumeCreatedAt: volumeCreatedAt
            )
            try drive.insert(db)
            return drive
        }
    }

    public func allDrives() throws -> [Drive] {
        try dbWriter.read { db in
            try Drive.order(Drive.Columns.lastSeenAt.desc).fetchAll(db)
        }
    }

    /// Persists the fields the user is allowed to correct.
    ///
    /// Deliberately narrow: everything else about a drive is observed from the
    /// hardware and would be overwritten on the next sighting anyway.
    public func updateDrive(
        id: Int64,
        isSolidStateOverride: Bool??? = nil,
        purchasedOn: Date??? = nil
    ) throws {
        try dbWriter.write { db in
            guard var drive = try Drive.fetchOne(db, key: id) else { return }
            // Triple optional so "don't touch" is distinguishable from "set to nil".
            if let newValue = isSolidStateOverride { drive.isSolidStateOverride = newValue ?? nil }
            if let newValue = purchasedOn { drive.purchasedOn = newValue ?? nil }
            try drive.update(db)
        }
    }

    /// Forgets a drive and everything catalogued from it.
    public func deleteDrive(id: Int64) throws {
        _ = try dbWriter.write { db in
            try Drive.deleteOne(db, key: id)
        }
    }

    public func folder(id: Int64) throws -> Folder? {
        try dbWriter.read { db in try Folder.fetchOne(db, key: id) }
    }

    /// Whether a folder has children, without loading them.
    ///
    /// The tree view needs this to decide whether to draw a disclosure triangle,
    /// and asking for it per visible row must not pull in a subtree.
    public func hasChildren(_ folderId: Int64) throws -> Bool {
        try dbWriter.read { db in
            try Folder.filter(Folder.Columns.parentId == folderId).fetchCount(db) > 0
        }
    }

    /// Path from the drive root down to `folder`, for breadcrumbs in search results.
    public func ancestors(of folder: Folder) throws -> [Folder] {
        try dbWriter.read { db in
            var chain: [Folder] = []
            var current = folder
            while let parentId = current.parentId,
                  let parent = try Folder.fetchOne(db, key: parentId) {
                chain.append(parent)
                current = parent
            }
            return chain.reversed()
        }
    }

    public func drive(volumeUUID: String) throws -> Drive? {
        try dbWriter.read { db in
            try Drive.filter(Drive.Columns.volumeUUID == volumeUUID).fetchOne(db)
        }
    }

    /// Flags a drive's catalog as stale (the change-watcher saw a modification).
    public func markNeedsRescan(volumeUUID: String) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE drive SET needsRescan = 1 WHERE volumeUUID = ?",
                arguments: [volumeUUID]
            )
        }
    }

    // MARK: - Folders

    public func rootFolder(driveId: Int64) throws -> Folder? {
        try dbWriter.read { db in
            try Folder
                .filter(Folder.Columns.driveId == driveId && Folder.Columns.parentId == nil)
                .fetchOne(db)
        }
    }

    public func children(of folderId: Int64) throws -> [Folder] {
        try dbWriter.read { db in
            try Folder
                .filter(Folder.Columns.parentId == folderId)
                .order(Folder.Columns.name)
                .fetchAll(db)
        }
    }

    /// Extension breakdown for a folder, biggest branch first.
    ///
    /// `rollup: true` includes descendants — that's what the hover popover shows.
    public func extensions(of folderId: Int64, rollup: Bool = true) throws -> [FolderExtension] {
        try dbWriter.read { db in
            let rows = try FolderExtension
                .filter(FolderExtension.Columns.folderId == folderId)
                .fetchAll(db)
            return rows
                .filter { rollup ? $0.rollCount > 0 : $0.ownCount > 0 }
                .sorted { rollup ? $0.rollBytes > $1.rollBytes : $0.ownBytes > $1.ownBytes }
        }
    }

    /// The file types that account for the most bytes on a drive.
    ///
    /// Sums `ownBytes`, never `rollBytes` — rollups are cumulative up the tree, so
    /// summing them across folders would count the same file once per ancestor.
    public func topExtensions(driveId: Int64, limit: Int = 4) throws -> [(ext: String, bytes: Int64)] {
        try dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT folder_ext.ext AS ext, SUM(folder_ext.ownBytes) AS bytes
                FROM folder_ext
                JOIN folder ON folder.id = folder_ext.folderId
                WHERE folder.driveId = ? AND folder_ext.ownBytes > 0
                GROUP BY folder_ext.ext
                ORDER BY bytes DESC
                LIMIT ?
                """, arguments: [driveId, limit])
                .map { (ext: $0["ext"] as String, bytes: $0["bytes"] as Int64) }
        }
    }

    /// The single biggest file type within each given folder's subtree.
    ///
    /// Batched deliberately: the treemap needs this for every visible tile, and
    /// one query per tile would be hundreds of round-trips per repaint.
    public func dominantExtensions(for folderIds: [Int64]) throws -> [Int64: String] {
        guard !folderIds.isEmpty else { return [:] }
        return try dbWriter.read { db in
            let placeholders = databaseQuestionMarks(count: folderIds.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT folderId, ext, rollBytes
                FROM folder_ext
                WHERE folderId IN (\(placeholders)) AND rollBytes > 0
                """, arguments: StatementArguments(folderIds))

            var best: [Int64: (ext: String, bytes: Int64)] = [:]
            for row in rows {
                let id: Int64 = row["folderId"]
                let ext: String = row["ext"]
                let bytes: Int64 = row["rollBytes"]
                if let existing = best[id], existing.bytes >= bytes { continue }
                best[id] = (ext, bytes)
            }
            return best.mapValues(\.ext)
        }
    }

    /// Folders worth donating to the system Spotlight index: biggest first,
    /// with a floor and a cap.
    ///
    /// The floor exists because nobody Spotlight-searches for a 40 KB folder,
    /// and the cap keeps a pathological drive from flooding the system index —
    /// Core Spotlight handles thousands of items happily, not hundreds of
    /// thousands.
    public func foldersForIndex(
        driveId: Int64,
        minBytes: Int64 = 10_000_000,
        limit: Int = 3000
    ) throws -> [Folder] {
        try dbWriter.read { db in
            try Folder
                .filter(Folder.Columns.driveId == driveId)
                .filter(Column("totalBytes") >= minBytes)
                .filter(Folder.Columns.path != "")
                .order(Column("totalBytes").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Full-text search over folder names across every catalogued drive,
    /// including drives that aren't currently plugged in.
    public func searchFolders(_ query: String, limit: Int = 200) throws -> [Folder] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return try dbWriter.read { db in
            // Prefix-match each token so "phot" finds "Photos" as you type.
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) else { return [] }
            return try Folder.fetchAll(db, sql: """
                SELECT folder.*
                FROM folder
                JOIN folder_fts ON folder_fts.rowid = folder.id
                WHERE folder_fts MATCH ?
                ORDER BY folder.totalBytes DESC
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }
}
