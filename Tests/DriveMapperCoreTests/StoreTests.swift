import Foundation
import Testing
@testable import DriveMapperCore

enum TestFailure: Error { case missingFolder }

@Suite("Store")
struct StoreTests {

    // MARK: - Drives

    @Test("A drive is created on first sighting and reused on the next")
    func recordSightingIsIdempotent() throws {
        let store = try Store()
        let first = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")
        let second = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")

        #expect(first.id == second.id)
        #expect(try store.allDrives().count == 1)
    }

    @Test("Reconnecting preserves first-seen date but refreshes last-seen")
    func sightingPreservesFirstSeen() throws {
        let store = try Store()
        let day1 = Date(timeIntervalSince1970: 1_600_000_000)
        let day2 = day1.addingTimeInterval(86_400 * 30)

        try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB", now: day1)
        let again = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB", now: day2)

        // firstSeenAt is the drive's age signal — it must survive reconnects.
        #expect(abs(again.firstSeenAt.timeIntervalSince(day1)) < 1)
        #expect(abs(again.lastSeenAt.timeIntervalSince(day2)) < 1)
    }

    @Test("A renamed drive keeps its identity and user-set fields")
    func sightingPreservesUserFields() throws {
        let store = try Store()
        var drive = try store.recordSighting(volumeUUID: "UUID-1", name: "Untitled")

        // User corrects the SSD detection and records when they bought it.
        let purchased = Date(timeIntervalSince1970: 1_500_000_000)
        drive.isSolidStateOverride = true
        drive.purchasedOn = purchased
        try store.dbWriter.write { db in try drive.update(db) }

        // Drive comes back with a new name and still-unknown SSD detection.
        let after = try store.recordSighting(
            volumeUUID: "UUID-1",
            name: "Photos Archive",
            isSolidStateDetected: nil
        )

        #expect(after.name == "Photos Archive")
        #expect(after.isSolidStateOverride == true)
        #expect(after.isSolidState == true, "override must win over nil detection")
        #expect(after.purchasedOn.map { abs($0.timeIntervalSince(purchased)) < 1 } == true)
    }

    @Test("Manual override takes precedence over diskutil detection")
    func overrideBeatsDetection() throws {
        var drive = Drive(volumeUUID: "U", name: "D", isSolidStateDetected: false)
        #expect(drive.isSolidState == false)

        drive.isSolidStateOverride = true
        #expect(drive.isSolidState == true)

        // The USB-enclosure case: diskutil says "Info not available".
        let unknown = Drive(volumeUUID: "U", name: "D")
        #expect(unknown.isSolidState == nil)
    }

    // MARK: - Age

    private func years(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .year, value: -n, to: Date())!
    }

    @Test("First-seen date is never used as an age basis")
    func firstSeenIsNotAnAge() {
        // The case that motivated this: a drive bought years ago and plugged into
        // this app for the very first time today. Using firstSeenAt as a proxy
        // reported it as brand new.
        let drive = Drive(
            volumeUUID: "U", name: "Old SSD",
            isSolidStateDetected: true,
            firstSeenAt: Date(), lastSeenAt: Date()
        )
        #expect(drive.ageBasis == .unknown)
        #expect(drive.ageReferenceDate == nil)
        #expect(drive.needsAgeInfo, "should prompt for a purchase date instead")
    }

    @Test("An old drive first seen today does not read as new")
    func oldDriveSeenTodayIsNotNew() {
        var drive = Drive(
            volumeUUID: "U", name: "2018 SSD",
            isSolidStateDetected: true,
            firstSeenAt: Date(), lastSeenAt: Date()
        )
        // Unknown age must not read as a clean bill of health…
        #expect(drive.isWearRisk() == false)
        #expect(drive.needsAgeInfo)

        // …and once the user says when they bought it, the warning fires.
        drive.purchasedOn = years(7)
        #expect(drive.isWearRisk())
        #expect(drive.needsAgeInfo == false)
    }

    @Test("Purchase date takes precedence over volume creation date")
    func purchaseBeatsFormatted() {
        var drive = Drive(volumeUUID: "U", name: "D", isSolidStateDetected: true)
        drive.volumeCreatedAt = years(1)
        #expect(drive.ageBasis == .formatted(drive.volumeCreatedAt!))
        #expect(drive.isWearRisk() == false)

        // A drive reformatted last year but bought eight years ago is an old
        // drive — the user's answer has to win.
        drive.purchasedOn = years(8)
        #expect(drive.ageBasis == .purchased(drive.purchasedOn!))
        #expect(drive.isWearRisk())
    }

    @Test("Wear warning applies to SSDs only")
    func wearWarningIsSSDOnly() {
        var hdd = Drive(volumeUUID: "U", name: "D", isSolidStateDetected: false)
        hdd.purchasedOn = years(10)
        #expect(hdd.isWearRisk() == false)
        #expect(hdd.needsAgeInfo == false, "no point prompting for an HDD")

        var unknownType = Drive(volumeUUID: "U", name: "D")
        unknownType.purchasedOn = years(10)
        #expect(unknownType.isWearRisk() == false, "type unknown, so no claim")
    }

    @Test("Wear threshold is a boundary, not a range")
    func wearThresholdBoundary() {
        var drive = Drive(volumeUUID: "U", name: "D", isSolidStateDetected: true)

        drive.purchasedOn = years(4)
        #expect(drive.isWearRisk() == false)

        drive.purchasedOn = years(5)
        #expect(drive.isWearRisk(), "5 years is the threshold, inclusive")
    }

    @Test("A user's SSD override enables the wear warning")
    func overrideEnablesWearWarning() {
        // The USB-enclosure path: diskutil couldn't tell, the user did.
        var drive = Drive(volumeUUID: "U", name: "D")
        drive.purchasedOn = years(6)
        #expect(drive.isWearRisk() == false, "type still unknown")

        drive.isSolidStateOverride = true
        #expect(drive.isWearRisk())
    }

    // MARK: - Folder tree

    @Test("A folder tree round-trips with parent/child links intact")
    func folderTreeRoundTrip() throws {
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")
        let driveId = try #require(drive.id)

        let rootId = try insert(store, driveId: driveId, parent: nil, name: "Backup4TB", path: "", depth: 0)
        let photosId = try insert(store, driveId: driveId, parent: rootId, name: "Photos", path: "Photos", depth: 1)
        _ = try insert(store, driveId: driveId, parent: rootId, name: "Projects", path: "Projects", depth: 1)
        _ = try insert(store, driveId: driveId, parent: photosId, name: "2019", path: "Photos/2019", depth: 2)

        let root = try #require(try store.rootFolder(driveId: driveId))
        #expect(root.id == rootId)

        let topLevel = try store.children(of: rootId)
        #expect(topLevel.map(\.name) == ["Photos", "Projects"], "children come back name-ordered")

        let underPhotos = try store.children(of: photosId)
        #expect(underPhotos.map(\.name) == ["2019"])
    }

    @Test("Migrations apply cleanly and leave createdAt usable")
    func migrationsIncludeCreatedAt() throws {
        // Exercises the real migrator against a fresh file-backed database, which
        // is the only way the v3 ALTER runs in the same order a user's existing
        // catalogue would see it.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dm-migrate-\(UUID().uuidString)/catalog.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = try Store(url: url)
        let drive = try store.recordSighting(volumeUUID: "M", name: "M")
        let driveId = try #require(drive.id)

        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try store.dbWriter.write { db -> Int64 in
            var f = Folder(
                driveId: driveId, name: "Photos", path: "Photos", depth: 1,
                createdAt: created
            )
            try f.insert(db)
            return f.id!
        }

        let readBack = try #require(try store.folder(id: id))
        #expect(readBack.createdAt.map { abs($0.timeIntervalSince(created)) < 1 } == true)

        // Reopening runs the migrator again; it must be a no-op, not an error.
        let reopened = try Store(url: url)
        #expect(try reopened.folder(id: id)?.name == "Photos")
    }

    @Test("hasChildren drives the disclosure arrow, so it must be exact")
    func hasChildrenIsAccurate() throws {
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")
        let driveId = try #require(drive.id)

        let rootId = try insert(store, driveId: driveId, parent: nil, name: "root", path: "", depth: 0)
        let photosId = try insert(store, driveId: driveId, parent: rootId, name: "Photos", path: "Photos", depth: 1)
        let emptyId = try insert(store, driveId: driveId, parent: rootId, name: "Empty", path: "Empty", depth: 1)
        _ = try insert(store, driveId: driveId, parent: photosId, name: "2019", path: "Photos/2019", depth: 2)

        // A wrong answer here means either a dead arrow on a folder that can't
        // open, or no arrow on one that could.
        #expect(try store.hasChildren(rootId))
        #expect(try store.hasChildren(photosId))
        #expect(try store.hasChildren(emptyId) == false)
    }

    @Test("Ancestors resolve from a folder back up to the drive root")
    func ancestorChain() throws {
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")
        let driveId = try #require(drive.id)

        let rootId = try insert(store, driveId: driveId, parent: nil, name: "root", path: "", depth: 0)
        let photosId = try insert(store, driveId: driveId, parent: rootId, name: "Photos", path: "Photos", depth: 1)
        let yearId = try insert(store, driveId: driveId, parent: photosId, name: "2019", path: "Photos/2019", depth: 2)

        let year = try #require(try store.folder(id: yearId))
        let chain = try store.ancestors(of: year)
        #expect(chain.map(\.name) == ["root", "Photos"], "ordered root-first for breadcrumbs")

        let root = try #require(try store.folder(id: rootId))
        #expect(try store.ancestors(of: root).isEmpty)
    }

    @Test("Deleting a drive cascades to its folders and extension stats")
    func deleteCascades() throws {
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")
        let driveId = try #require(drive.id)

        let rootId = try insert(store, driveId: driveId, parent: nil, name: "Backup4TB", path: "", depth: 0)
        try store.dbWriter.write { db in
            try FolderExtension(folderId: rootId, ext: "raf", ownCount: 3, rollCount: 3).insert(db)
        }

        try store.dbWriter.write { db in _ = try Drive.deleteAll(db) }

        let (folders, exts) = try store.dbWriter.read { db in
            (try Folder.fetchCount(db), try FolderExtension.fetchCount(db))
        }
        #expect(folders == 0)
        #expect(exts == 0)
    }

    // MARK: - Extension stats

    @Test("Own and rollup extension stats are stored and read separately")
    func extensionRollup() throws {
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")
        let driveId = try #require(drive.id)
        let rootId = try insert(store, driveId: driveId, parent: nil, name: "Backup4TB", path: "", depth: 0)

        try store.dbWriter.write { db in
            // Nothing directly in root, but 400 .raf and 12 .mov below it. This is
            // exactly the case where a rollup-less hover would show an empty tooltip.
            try FolderExtension(
                folderId: rootId, ext: "raf",
                ownCount: 0, ownBytes: 0, rollCount: 400, rollBytes: 8_000_000_000
            ).insert(db)
            try FolderExtension(
                folderId: rootId, ext: "mov",
                ownCount: 0, ownBytes: 0, rollCount: 12, rollBytes: 24_000_000_000
            ).insert(db)
        }

        let rolled = try store.extensions(of: rootId, rollup: true)
        #expect(rolled.map(\.ext) == ["mov", "raf"], "sorted by size, not count")
        #expect(rolled.first?.rollCount == 12)

        let own = try store.extensions(of: rootId, rollup: false)
        #expect(own.isEmpty, "no files live directly in root")
    }

    // MARK: - Search

    @Test("Search finds folders across drives, including disconnected ones")
    func searchAcrossDrives() throws {
        let store = try Store()
        let a = try #require(try store.recordSighting(volumeUUID: "A", name: "Drive A").id)
        let b = try #require(try store.recordSighting(volumeUUID: "B", name: "Drive B").id)

        _ = try insert(store, driveId: a, parent: nil, name: "Drive A", path: "", depth: 0)
        _ = try insert(store, driveId: a, parent: nil, name: "Wedding Photos", path: "Wedding Photos", depth: 1)
        _ = try insert(store, driveId: b, parent: nil, name: "Drive B", path: "", depth: 0)
        _ = try insert(store, driveId: b, parent: nil, name: "Holiday Photos", path: "Holiday Photos", depth: 1)

        let hits = try store.searchFolders("photos")
        #expect(hits.count == 2)
        #expect(Set(hits.map(\.driveId)) == Set([a, b]), "spans both drives")
    }

    @Test("Search matches prefixes so it works while typing")
    func searchPrefix() throws {
        let store = try Store()
        let driveId = try #require(try store.recordSighting(volumeUUID: "A", name: "Drive A").id)
        _ = try insert(store, driveId: driveId, parent: nil, name: "Photography", path: "Photography", depth: 0)

        #expect(try store.searchFolders("phot").count == 1)
        #expect(try store.searchFolders("Phot").count == 1, "case-insensitive")
        #expect(try store.searchFolders("xyz").isEmpty)
        #expect(try store.searchFolders("   ").isEmpty, "blank query is not a match-everything")
    }

    @Test("Renaming a folder updates the search index")
    func searchIndexFollowsUpdates() throws {
        let store = try Store()
        let driveId = try #require(try store.recordSighting(volumeUUID: "A", name: "Drive A").id)
        let id = try insert(store, driveId: driveId, parent: nil, name: "Untitled", path: "x", depth: 0)

        try store.dbWriter.write { db in
            guard var f = try Folder.fetchOne(db, key: id) else {
                throw TestFailure.missingFolder
            }
            f.name = "Renders"
            try f.update(db)
        }

        // The FTS triggers must have followed the rename, not just the insert.
        #expect(try store.searchFolders("Renders").count == 1)
        #expect(try store.searchFolders("Untitled").isEmpty)
    }

    // MARK: - Needs-rescan flag

    @Test("A fresh drive isn't flagged for rescan")
    func newDriveNotStale() throws {
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")
        #expect(drive.needsRescan == false)
    }

    @Test("markNeedsRescan sets the flag and it survives across loads")
    func markNeedsRescanPersists() throws {
        let store = try Store()
        try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")

        try store.markNeedsRescan(volumeUUID: "UUID-1")

        let reloaded = try #require(try store.drive(volumeUUID: "UUID-1"))
        #expect(reloaded.needsRescan == true)
    }

    @Test("Recording a sighting doesn't clear an existing rescan flag")
    func sightingKeepsStaleFlag() throws {
        // A drive changed, was unplugged, then plugged back in: it's still stale
        // until an actual scan runs, so a bare reconnect must not clear the flag.
        let store = try Store()
        try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")
        try store.markNeedsRescan(volumeUUID: "UUID-1")

        let after = try store.recordSighting(volumeUUID: "UUID-1", name: "Backup4TB")
        #expect(after.needsRescan == true)
    }

    // MARK: - Helper

    @discardableResult
    private func insert(
        _ store: Store, driveId: Int64, parent: Int64?, name: String, path: String, depth: Int
    ) throws -> Int64 {
        try store.dbWriter.write { db in
            var f = Folder(driveId: driveId, parentId: parent, name: name, path: path, depth: depth)
            try f.insert(db)
            return f.id!
        }
    }
}
