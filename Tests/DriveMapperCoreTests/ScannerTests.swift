import Foundation
import GRDB
import Testing
@testable import DriveMapperCore

@Suite("Scanner")
struct ScannerTests {

    // MARK: - Fixture

    /// Builds a tree on disk and tears it down afterwards.
    ///
    ///     root/
    ///       Photos/
    ///         2019/  a.raf (100B)  b.raf (200B)
    ///         2020/  c.jpg (50B)
    ///       Projects/
    ///         site/  index.html (10B)  node_modules/ (skipped)
    ///       notes.txt (5B)
    final class Fixture {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "drivemapper-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            try dir("Photos/2019")
            try dir("Photos/2020")
            try dir("Projects/site/node_modules/left-pad")
            try file("Photos/2019/a.raf", bytes: 100)
            try file("Photos/2019/b.raf", bytes: 200)
            try file("Photos/2020/c.jpg", bytes: 50)
            try file("Projects/site/index.html", bytes: 10)
            try file("Projects/site/node_modules/left-pad/index.js", bytes: 999)
            try file("notes.txt", bytes: 5)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func dir(_ path: String) throws {
            try FileManager.default.createDirectory(
                at: root.appending(path: path), withIntermediateDirectories: true
            )
        }

        func file(_ path: String, bytes: Int) throws {
            try Data(repeating: 0x41, count: bytes).write(to: root.appending(path: path))
        }

        func remove(_ path: String) throws {
            try FileManager.default.removeItem(at: root.appending(path: path))
        }

        func move(_ from: String, to: String) throws {
            try FileManager.default.moveItem(
                at: root.appending(path: from), to: root.appending(path: to)
            )
        }
    }

    private func makeStore() throws -> (Store, Int64) {
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "TEST-UUID", name: "TestDrive")
        return (store, drive.id!)
    }

    private func folder(_ store: Store, _ driveId: Int64, path: String) throws -> Folder? {
        try store.dbWriter.read { db in
            try Folder
                .filter(Folder.Columns.driveId == driveId && Folder.Columns.path == path)
                .fetchOne(db)
        }
    }

    // MARK: - Structure

    @Test("Scan records the folder tree with correct paths and depths")
    func scanRecordsTree() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)

        let summary = try await scanner.scan(volumeURL: fixture.root, driveId: driveId, rootName: "TestDrive")

        let root = try #require(try store.rootFolder(driveId: driveId))
        #expect(root.name == "TestDrive")
        #expect(root.path == "")
        #expect(root.depth == 0)

        let photos = try #require(try folder(store, driveId, path: "Photos"))
        #expect(photos.depth == 1)
        #expect(photos.parentId == root.id)

        let y2019 = try #require(try folder(store, driveId, path: "Photos/2019"))
        #expect(y2019.depth == 2)
        #expect(y2019.parentId == photos.id)

        // root, Photos, 2019, 2020, Projects, site, node_modules
        #expect(summary.folderCount == 7)
    }

    @Test("Sizes roll up from leaves to the root")
    func sizesRollUp() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let y2019 = try #require(try folder(store, driveId, path: "Photos/2019"))
        #expect(y2019.ownBytes == 300)
        #expect(y2019.totalBytes == 300)
        #expect(y2019.ownFileCount == 2)

        let photos = try #require(try folder(store, driveId, path: "Photos"))
        #expect(photos.ownBytes == 0, "no files directly in Photos")
        #expect(photos.totalBytes == 350, "300 from 2019 + 50 from 2020")
        #expect(photos.totalFileCount == 3)

        let root = try #require(try store.rootFolder(driveId: driveId))
        // 350 photos + 10 index.html + 5 notes.txt. node_modules is NOT counted.
        #expect(root.totalBytes == 365)
        #expect(root.ownBytes == 5, "just notes.txt")
    }

    // MARK: - Extension stats

    @Test("Rollup extensions aggregate across descendants, own stays local")
    func extensionRollups() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let photosId = try #require(try folder(store, driveId, path: "Photos")?.id)

        // This is the hover-tooltip case: nothing directly in Photos, but the
        // branch below it is 2 .raf and 1 .jpg.
        let rolled = try store.extensions(of: photosId, rollup: true)
        let byExt = Dictionary(uniqueKeysWithValues: rolled.map { ($0.ext, $0) })
        #expect(byExt["raf"]?.rollCount == 2)
        #expect(byExt["raf"]?.rollBytes == 300)
        #expect(byExt["jpg"]?.rollCount == 1)

        #expect(try store.extensions(of: photosId, rollup: false).isEmpty)

        // And directly-held files show up in the own view.
        let y2019Id = try #require(try folder(store, driveId, path: "Photos/2019")?.id)
        let own = try store.extensions(of: y2019Id, rollup: false)
        #expect(own.count == 1)
        #expect(own.first?.ownCount == 2)
    }

    // MARK: - Mid-scan failure

    @Test("Scanning a vanished volume preserves the previous catalogue")
    func vanishedVolumePreservesCatalog() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let before = try await store.dbWriter.read { db in try Folder.fetchCount(db) }
        #expect(before == 7)

        // The drive is gone by the time the rescan starts.
        let gone = fixture.root.appending(path: "does-not-exist")
        await #expect(throws: Scanner.ScanError.self) {
            try await scanner.scan(volumeURL: gone, driveId: driveId)
        }

        // The failed scan must have rolled back — this is the whole point.
        let after = try await store.dbWriter.read { db in try Folder.fetchCount(db) }
        #expect(after == 7, "old catalogue survives a failed scan")
    }

    @Test("Unplugging mid-scan rolls back instead of committing a gutted tree")
    func midScanUnplugRollsBack() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)
        let before = try await store.dbWriter.read { db in try Folder.fetchCount(db) }

        // Simulate the unplug from inside the walk: the progress callback fires
        // after the root is recorded, and deleting the tree at that moment makes
        // every subsequent directory read fail — exactly what a yanked cable does.
        let root = fixture.root
        await #expect(throws: Scanner.ScanError.self) {
            try await scanner.scan(volumeURL: root, driveId: driveId) { _ in
                try? FileManager.default.removeItem(at: root)
            }
        }

        let after = try await store.dbWriter.read { db in try Folder.fetchCount(db) }
        #expect(after == before, "catalogue must not be replaced by the husk")
    }

    // MARK: - Timestamps

    @Test("Scanning records creation and modification dates")
    func recordsTimestamps() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let photos = try #require(try folder(store, driveId, path: "Photos"))
        // Sorting by date is only meaningful if these are actually populated —
        // createdAt was added to the schema after the fact.
        #expect(photos.createdAt != nil)
        #expect(photos.mtime != nil)

        let recent = Date().addingTimeInterval(-300)
        #expect(photos.createdAt! > recent, "fixture was made moments ago")
    }

    @Test("Leaf bundles carry timestamps too")
    func leafBundlesHaveTimestamps() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        // These take an early-return path in the walk, so they're easy to forget.
        let nm = try #require(try folder(store, driveId, path: "Projects/site/node_modules"))
        #expect(nm.createdAt != nil)
        #expect(nm.mtime != nil)
    }

    // MARK: - Treemap inputs

    @Test("Top extensions sum each file once, not once per ancestor")
    func topExtensionsDoNotDoubleCount() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let top = try store.topExtensions(driveId: driveId, limit: 10)
        let byExt = Dictionary(uniqueKeysWithValues: top.map { ($0.ext, $0.bytes) })

        // The two .raf files sit in Photos/2019, so they appear in the rollups of
        // 2019, Photos AND root. Summing rollBytes would report 900 instead of 300.
        #expect(byExt["raf"] == 300)
        #expect(byExt["jpg"] == 50)
        #expect(byExt["html"] == 10)
        #expect(byExt["txt"] == 5)
        #expect(byExt["js"] == nil, "node_modules contents are never indexed")
    }

    @Test("Top extensions come back biggest first")
    func topExtensionsAreOrdered() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let top = try store.topExtensions(driveId: driveId, limit: 2)
        #expect(top.count == 2, "limit is respected — the palette only has 4 slots")
        #expect(top.map(\.ext) == ["raf", "jpg"])
    }

    @Test("Dominant extension per folder reflects the whole subtree")
    func dominantExtensionPerFolder() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let photos = try #require(try folder(store, driveId, path: "Photos"))
        let year = try #require(try folder(store, driveId, path: "Photos/2019"))
        let site = try #require(try folder(store, driveId, path: "Projects/site"))

        let dominant = try store.dominantExtensions(for: [photos.id!, year.id!, site.id!])

        // Photos holds no files itself — its colour has to come from the subtree,
        // or every top-level folder in the treemap would be "Other".
        #expect(dominant[photos.id!] == "raf")
        #expect(dominant[year.id!] == "raf")
        #expect(dominant[site.id!] == "html")
    }

    @Test("Dominant extensions handle an empty request")
    func dominantExtensionsEmptyInput() throws {
        let store = try Store()
        #expect(try store.dominantExtensions(for: []).isEmpty)
    }

    // MARK: - Skipping

    @Test("node_modules is recorded but not descended into or sized")
    func skipsBuildDirectories() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let nm = try #require(try folder(store, driveId, path: "Projects/site/node_modules"))
        #expect(nm.isLeafBundle)
        #expect(nm.totalBytes == 0, "deliberately unsized — walking it is the cost we avoid")

        // Its contents must not appear as browsable folders.
        #expect(try folder(store, driveId, path: "Projects/site/node_modules/left-pad") == nil)

        let site = try #require(try folder(store, driveId, path: "Projects/site"))
        #expect(site.totalBytes == 10, "the 999-byte file inside node_modules is excluded")
    }

    @Test("Packages are sized but their internals aren't recorded")
    func packagesAreSizedNotDescended() async throws {
        let fixture = try Fixture()
        try fixture.dir("Apps/Thing.app/Contents")
        try fixture.file("Apps/Thing.app/Contents/binary", bytes: 400)

        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let app = try #require(try folder(store, driveId, path: "Apps/Thing.app"))
        #expect(app.isLeafBundle)
        #expect(app.totalBytes == 400, "packages are user data, so we do measure them")
        #expect(try folder(store, driveId, path: "Apps/Thing.app/Contents") == nil)
    }

    @Test("Symlinks are not followed")
    func doesNotFollowSymlinks() async throws {
        let fixture = try Fixture()
        // A loop: Photos/loop -> the root itself. An unguarded walk never terminates.
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appending(path: "Photos/loop"),
            withDestinationURL: fixture.root
        )

        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        let summary = try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        #expect(summary.folderCount == 7, "the symlink adds nothing")
        #expect(try folder(store, driveId, path: "Photos/loop") == nil)
    }

    // MARK: - Rescan

    @Test("A file added four levels deep is picked up on rescan")
    func rescanCatchesDeepChange() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let before = try #require(try store.rootFolder(driveId: driveId))
        #expect(before.totalBytes == 365)

        // This is the exact case that makes mtime-based subtree pruning unsound:
        // adding this file bumps 2019's mtime but leaves Photos' and root's
        // untouched. A scanner that pruned on ancestor mtime would miss it.
        try fixture.file("Photos/2019/d.raf", bytes: 700)

        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        let after = try #require(try store.rootFolder(driveId: driveId))
        #expect(after.totalBytes == 1065, "root total reflects a change 3 levels below it")

        let y2019 = try #require(try folder(store, driveId, path: "Photos/2019"))
        #expect(y2019.ownFileCount == 3)
    }

    @Test("Renaming a folder replaces the old path and keeps the tree consistent")
    func rescanHandlesRename() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        try fixture.move("Photos/2019", to: "Photos/2019-archive")
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        #expect(try folder(store, driveId, path: "Photos/2019") == nil, "stale path is gone")
        let renamed = try #require(try folder(store, driveId, path: "Photos/2019-archive"))
        #expect(renamed.totalBytes == 300, "contents came along")

        // Search must follow too, or the catalog lies about what's on the drive.
        #expect(try store.searchFolders("2019-archive").count == 1)
    }

    @Test("Deleting a subtree removes it from the catalog")
    func rescanHandlesDeletion() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)
        #expect(try folder(store, driveId, path: "Photos/2020") != nil)

        try fixture.remove("Photos/2020")
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)

        #expect(try folder(store, driveId, path: "Photos/2020") == nil)
        let photos = try #require(try folder(store, driveId, path: "Photos"))
        #expect(photos.totalBytes == 300, "the 50 bytes went with it")
    }

    @Test("Rescanning doesn't duplicate rows")
    func rescanIsNotAdditive() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)

        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)
        let firstCount = try await store.dbWriter.read { db in try Folder.fetchCount(db) }

        try await scanner.scan(volumeURL: fixture.root, driveId: driveId)
        let secondCount = try await store.dbWriter.read { db in try Folder.fetchCount(db) }

        #expect(firstCount == secondCount)
    }

    @Test("Scanning one drive leaves other drives' data alone")
    func scanIsScopedToOneDrive() async throws {
        let fixture = try Fixture()
        let store = try Store()
        let driveA = try store.recordSighting(volumeUUID: "A", name: "A").id!
        let driveB = try store.recordSighting(volumeUUID: "B", name: "B").id!
        let scanner = Scanner(store: store)

        try await scanner.scan(volumeURL: fixture.root, driveId: driveA)
        try await scanner.scan(volumeURL: fixture.root, driveId: driveB)
        // Rescanning A must not disturb B.
        try await scanner.scan(volumeURL: fixture.root, driveId: driveA)

        let bFolders = try await store.dbWriter.read { db in
            try Folder.filter(Folder.Columns.driveId == driveB).fetchCount(db)
        }
        #expect(bFolders == 7)
    }

    // MARK: - Bookkeeping

    @Test("Scan stamps lastScannedAt and reports progress")
    func scanReportsProgress() async throws {
        let fixture = try Fixture()
        let (store, driveId) = try makeStore()
        let scanner = Scanner(store: store)

        let counter = ProgressCounter()
        try await scanner.scan(volumeURL: fixture.root, driveId: driveId) { _ in
            counter.increment()
        }

        #expect(counter.value > 0, "progress callback fired")
        let drive = try #require(try store.drive(volumeUUID: "TEST-UUID"))
        #expect(drive.lastScannedAt != nil)
    }
}

/// Minimal thread-safe counter — the progress callback is `@Sendable`.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
