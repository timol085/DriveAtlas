import Foundation
import GRDB
import Testing
@testable import DriveMapperCore

@Suite("CopyAnalysis")
struct CopyAnalysisTests {

    private let gb: Int64 = 1_000_000_000

    /// Builds a store with drives and folders, sized in GB.
    ///
    /// Each folder gets synthetic file fingerprints derived from its **name** and
    /// **size**: a file count proportional to size, each print keyed on the
    /// folder name. So two folders with the same name and size hold identical
    /// content (→ match), near-equal sizes share most files (→ still match), and
    /// different names or wildly different sizes share little (→ no match) — the
    /// content-matching equivalent of the old name+size behaviour, which is what
    /// lets the pre-existing expectations carry over unchanged.
    ///
    /// Pass an explicit `contentKey` when you want two *differently named*
    /// folders to hold the same content (the new cross-name capability).
    private func makeStore(
        _ layout: [(drive: String, folders: [(path: String, gb: Double, contentKey: String?)])]
    ) throws -> Store {
        let store = try Store()
        for entry in layout {
            let drive = try store.recordSighting(volumeUUID: entry.drive, name: entry.drive)
            let driveId = drive.id!
            try store.dbWriter.write { db in
                try db.execute(sql: "UPDATE drive SET contentScanned = 1 WHERE id = ?", arguments: [driveId])
                var root = Folder(driveId: driveId, name: entry.drive, path: "", depth: 0)
                try root.insert(db)

                // Link each folder to its parent by path, exactly as the real
                // scanner does — the matcher needs parentId to roll content up.
                var idByPath: [String: Int64] = ["": root.id!]

                for folder in entry.folders {
                    let components = folder.path.split(separator: "/").map(String.init)
                    let name = components.last ?? ""
                    let parentPath = components.dropLast().joined(separator: "/")
                    var f = Folder(
                        driveId: driveId,
                        parentId: idByPath[parentPath] ?? root.id!,
                        name: name,
                        path: folder.path,
                        depth: components.count,
                        totalBytes: Int64(folder.gb * Double(self.gb)),
                        totalFileCount: 10
                    )
                    try f.insert(db)
                    idByPath[folder.path] = f.id!

                    let key = folder.contentKey ?? name
                    let fileCount = max(Int(folder.gb * 20), 5)
                    let prints = Set((0..<fileCount).map {
                        FilePrint.of(name: "\(key)-file\($0)", size: 1000)
                    })
                    try db.execute(
                        sql: "UPDATE folder SET filePrints = ? WHERE id = ?",
                        arguments: [FilePrint.pack(prints), f.id!]
                    )
                }
            }
        }
        return store
    }

    /// Convenience: the common case where content follows the folder name.
    private func makeStore(
        _ layout: [(drive: String, folders: [(path: String, gb: Double)])]
    ) throws -> Store {
        try makeStore(layout.map { entry in
            (entry.drive, entry.folders.map { ($0.path, $0.gb, String?.none) })
        })
    }

    // MARK: - The core question

    @Test("A folder on one drive is at risk; the same folder on two is not")
    func singleCopyIsAtRisk() throws {
        let store = try makeStore([
            ("DriveA", [("Wedding RAWs", 80), ("Music", 40)]),
            ("DriveB", [("Music", 40)]),
        ])

        let analysis = try store.analyseCopies()

        #expect(analysis.atRisk.map(\.name) == ["Wedding RAWs"])
        #expect(analysis.duplicated.map(\.name) == ["Music"])
        #expect(analysis.duplicated.first?.driveCount == 2)
    }

    @Test("Two copies on the SAME drive are not a backup")
    func sameDriveCopiesAreNotBackup() throws {
        // The distinction that matters: duplicating a folder within one drive
        // protects you from nothing if that drive dies.
        let store = try makeStore([
            ("DriveA", [("Photos", 50), ("Backup/Photos", 50)]),
        ])

        let analysis = try store.analyseCopies()
        #expect(analysis.duplicated.isEmpty, "same drive twice is still one drive")
        #expect(analysis.atRisk.contains { $0.name == "Photos" })
    }

    @Test("Copies that differ slightly in size still match")
    func sizeToleranceMatchesNearCopies() throws {
        // Real copies are rarely byte-identical — a stray .DS_Store is enough.
        let store = try makeStore([
            ("DriveA", [("Trip Italy", 30.0)]),
            ("DriveB", [("Trip Italy", 29.4)]),   // 2% smaller
        ])

        let analysis = try store.analyseCopies()
        #expect(analysis.duplicated.count == 1)
        #expect(analysis.atRisk.isEmpty)
    }

    @Test("Same name but wildly different size is not a copy")
    func sizeMismatchIsNotACopy() throws {
        // Everyone has a "Photos" folder. Name alone would call these backups of
        // each other and tell you your data is safe when it isn't.
        let store = try makeStore([
            ("DriveA", [("Photos", 500)]),
            ("DriveB", [("Photos", 12)]),
        ])

        let analysis = try store.analyseCopies()
        #expect(analysis.duplicated.isEmpty)
        #expect(analysis.atRisk.count == 2, "both are unbacked, separately")
    }

    // MARK: - Noise suppression

    @Test("Small folders are ignored")
    func smallFoldersIgnored() throws {
        let store = try makeStore([
            ("DriveA", [("Tiny", 0.01), ("Big", 50)]),
        ])

        let analysis = try store.analyseCopies(minBytes: 100_000_000)
        #expect(analysis.atRisk.map(\.name) == ["Big"])
    }

    @Test("Drive roots are never reported")
    func driveRootsExcluded() throws {
        let store = try makeStore([("DriveA", [("Stuff", 50)])])
        let analysis = try store.analyseCopies()
        #expect(analysis.atRisk.allSatisfy { !$0.locations.contains { $0.path.isEmpty } })
        #expect(analysis.atRisk.map(\.name) == ["Stuff"])
    }

    @Test("Children of an at-risk folder aren't listed separately")
    func descendantsSuppressed() throws {
        // If Photos has no second copy then neither does Photos/2019. Listing both
        // buries the useful row under its own children.
        let store = try makeStore([
            ("DriveA", [
                ("Photos", 90),
                ("Photos/2019", 45),
                ("Photos/2019/Raw", 30),
                ("Projects", 20),
            ]),
        ])

        let analysis = try store.analyseCopies()
        #expect(Set(analysis.atRisk.map(\.name)) == ["Photos", "Projects"])
    }

    @Test("A similarly-named folder on another path isn't wrongly suppressed")
    func suppressionIsPrefixExact() throws {
        // "Photos" must not swallow "PhotosOld" — a naive prefix check would.
        let store = try makeStore([
            ("DriveA", [("Photos", 90), ("PhotosOld", 20)]),
        ])

        let analysis = try store.analyseCopies()
        #expect(Set(analysis.atRisk.map(\.name)) == ["Photos", "PhotosOld"])
    }

    // MARK: - Reporting

    @Test("Reclaimable space counts every copy but the largest")
    func reclaimableBytes() throws {
        let store = try makeStore([
            ("DriveA", [("Music", 40)]),
            ("DriveB", [("Music", 40)]),
            ("DriveC", [("Music", 40)]),
        ])

        let analysis = try store.analyseCopies()
        let group = try #require(analysis.duplicated.first)
        #expect(group.driveCount == 3)
        // Keep one, delete two.
        #expect(group.reclaimableBytes == 80 * gb)
    }

    @Test("At-risk is ranked biggest first")
    func atRiskOrdering() throws {
        let store = try makeStore([
            ("DriveA", [("Small", 5), ("Huge", 500), ("Medium", 50)]),
        ])

        let analysis = try store.analyseCopies()
        #expect(analysis.atRisk.map(\.name) == ["Huge", "Medium", "Small"])
    }

    @Test("Group reports which drives hold it, without repeats")
    func driveNames() throws {
        let store = try makeStore([
            ("DriveA", [("Music", 40)]),
            ("DriveB", [("Music", 40)]),
        ])

        let group = try #require(try store.analyseCopies().duplicated.first)
        #expect(Set(group.driveNames) == ["DriveA", "DriveB"])
        #expect(group.driveNames.count == 2)
    }

    @Test("An empty catalog produces empty results, not a crash")
    func emptyCatalog() throws {
        let store = try Store()
        let analysis = try store.analyseCopies()
        #expect(analysis.atRisk.isEmpty)
        #expect(analysis.duplicated.isEmpty)
        #expect(analysis.reclaimableBytes == 0)
    }
}

@Suite("CopyAnalysis.SortField")
struct CopyAnalysisSortTests {
    private let gb: Int64 = 1_000_000_000

    /// Build a group with one location on `drive`, of `sizeGB`.
    private func single(_ name: String, drive: String, gb sizeGB: Double) -> CopyAnalysis.Group {
        CopyAnalysis.Group(name: name, locations: [
            CopyAnalysis.Location(
                driveId: Int64(abs(drive.hashValue % 1000)),
                driveName: drive,
                folderId: Int64(abs(name.hashValue % 100000)),
                path: name,
                totalBytes: Int64(sizeGB * Double(gb)),
                totalFileCount: 10
            )
        ])
    }

    /// A group duplicated across several drives; sizes list is one per drive.
    private func across(_ name: String, drives: [String], gb sizes: [Double]) -> CopyAnalysis.Group {
        let locations = zip(drives, sizes).enumerated().map { i, pair in
            CopyAnalysis.Location(
                driveId: Int64(i + 1),
                driveName: pair.0,
                folderId: Int64(i * 1000 + abs(name.hashValue % 900)),
                path: name,
                totalBytes: Int64(pair.1 * Double(gb)),
                totalFileCount: 10
            )
        }
        return CopyAnalysis.Group(name: name, locations: locations)
    }

    @Test("Size descending is the default order")
    func sizeDescending() {
        let groups = [single("A", drive: "D1", gb: 10),
                      single("B", drive: "D1", gb: 90),
                      single("C", drive: "D1", gb: 40)]
        let out = groups.sorted(by: .size, ascending: false).map(\.name)
        #expect(out == ["B", "C", "A"])
    }

    @Test("Size ascending flips it")
    func sizeAscending() {
        let groups = [single("A", drive: "D1", gb: 10),
                      single("B", drive: "D1", gb: 90),
                      single("C", drive: "D1", gb: 40)]
        #expect(groups.sorted(by: .size, ascending: true).map(\.name) == ["A", "C", "B"])
    }

    @Test("Name sorts naturally, case- and number-aware")
    func nameNatural() {
        let groups = [single("Day 10", drive: "D1", gb: 5),
                      single("Day 2", drive: "D1", gb: 5),
                      single("day 1", drive: "D1", gb: 5)]
        // localizedStandard: "day 1" < "Day 2" < "Day 10" (numeric, case-insensitive)
        #expect(groups.sorted(by: .name, ascending: true).map(\.name) == ["day 1", "Day 2", "Day 10"])
    }

    @Test("Drive sort groups by which drive holds the orphan, name-tiebroken")
    func driveSort() {
        let groups = [single("Zebra", drive: "Alpha", gb: 5),
                      single("Apple", drive: "Alpha", gb: 5),
                      single("Middle", drive: "Beta", gb: 5)]
        let out = groups.sorted(by: .drive, ascending: true).map(\.name)
        // Alpha's two come first (name-ordered), then Beta's.
        #expect(out == ["Apple", "Zebra", "Middle"])
    }

    @Test("Reclaimable sorts by recoverable space, most first")
    func reclaimable() {
        // reclaimable = sum of all copies except the largest.
        let big = across("Big", drives: ["D1", "D2", "D3"], gb: [50, 50, 50])   // reclaim 100
        let small = across("Small", drives: ["D1", "D2"], gb: [30, 30])          // reclaim 30
        let out = [small, big].sorted(by: .reclaimable, ascending: false).map(\.name)
        #expect(out == ["Big", "Small"])
    }

    @Test("Copies sorts by how many drives hold it")
    func copies() {
        let two = across("Two", drives: ["D1", "D2"], gb: [10, 10])
        let four = across("Four", drives: ["D1", "D2", "D3", "D4"], gb: [10, 10, 10, 10])
        #expect([two, four].sorted(by: .copies, ascending: false).map(\.name) == ["Four", "Two"])
    }

    @Test("Ties always break on name, so order is stable")
    func tieBreak() {
        let groups = [single("Charlie", drive: "D1", gb: 40),
                      single("Alpha", drive: "D1", gb: 40),
                      single("Bravo", drive: "D1", gb: 40)]
        // All same size → name order, regardless of direction.
        #expect(groups.sorted(by: .size, ascending: false).map(\.name) == ["Alpha", "Bravo", "Charlie"])
        #expect(groups.sorted(by: .size, ascending: true).map(\.name) == ["Alpha", "Bravo", "Charlie"])
    }

    @Test("Field applicability differs by list")
    func fieldsPerList() {
        // Single-copy groups can't reclaim and always span one drive.
        #expect(CopyAnalysis.SortField.fields(duplicated: false) == [.size, .name, .drive])
        #expect(CopyAnalysis.SortField.fields(duplicated: true) == [.reclaimable, .size, .copies, .name])
    }

    @Test("Quantitative fields default descending, text fields ascending")
    func defaultDirections() {
        #expect(CopyAnalysis.SortField.size.defaultsDescending)
        #expect(CopyAnalysis.SortField.reclaimable.defaultsDescending)
        #expect(CopyAnalysis.SortField.copies.defaultsDescending)
        #expect(!CopyAnalysis.SortField.name.defaultsDescending)
        #expect(!CopyAnalysis.SortField.drive.defaultsDescending)
    }
}

@Suite("Content-based matching (store integration)")
struct ContentMatchStoreTests {
    private let gb: Int64 = 1_000_000_000

    private func makeStore(
        _ layout: [(drive: String, folders: [(path: String, gb: Double, contentKey: String?)])]
    ) throws -> Store {
        let store = try Store()
        for entry in layout {
            let drive = try store.recordSighting(volumeUUID: entry.drive, name: entry.drive)
            let driveId = drive.id!
            try store.dbWriter.write { db in
                try db.execute(sql: "UPDATE drive SET contentScanned = 1 WHERE id = ?", arguments: [driveId])
                var root = Folder(driveId: driveId, name: entry.drive, path: "", depth: 0)
                try root.insert(db)
                var idByPath: [String: Int64] = ["": root.id!]
                for folder in entry.folders {
                    let components = folder.path.split(separator: "/").map(String.init)
                    let name = components.last ?? ""
                    let parentPath = components.dropLast().joined(separator: "/")
                    var f = Folder(
                        driveId: driveId, parentId: idByPath[parentPath] ?? root.id!,
                        name: name, path: folder.path, depth: components.count,
                        totalBytes: Int64(folder.gb * Double(gb)), totalFileCount: 10
                    )
                    try f.insert(db)
                    idByPath[folder.path] = f.id!
                    let key = folder.contentKey ?? name
                    let prints = Set((0..<max(Int(folder.gb * 20), 5)).map {
                        FilePrint.of(name: "\(key)-file\($0)", size: 1000)
                    })
                    try db.execute(sql: "UPDATE folder SET filePrints = ? WHERE id = ?",
                                   arguments: [FilePrint.pack(prints), f.id!])
                }
            }
        }
        return store
    }

    @Test("Same content under DIFFERENT folder names is found as a copy")
    func differentNameSameContentMatches() throws {
        // The feature: "Japan" on Travel and "JP trip" on TimSSD hold the same
        // files. Name-only matching missed this; content matching catches it.
        let store = try makeStore([
            ("Travel", [("Japan", 30, "trip2024")]),
            ("TimSSD", [("JP trip", 30, "trip2024")]),
        ])
        let analysis = try store.analyseCopies()

        #expect(analysis.duplicated.count == 1)
        #expect(analysis.atRisk.isEmpty)
        let group = try #require(analysis.duplicated.first)
        #expect(group.driveCount == 2)
        // Each location shows its own (different) folder path.
        #expect(Set(group.locations.map(\.path)) == ["Japan", "JP trip"])
        #expect(group.overlap == 1.0)
    }

    @Test("Different names AND different content stay at risk")
    func differentNameDifferentContent() throws {
        let store = try makeStore([
            ("Travel", [("Japan", 30, "japan")]),
            ("TimSSD", [("Norway", 30, "norway")]),
        ])
        let analysis = try store.analyseCopies()
        #expect(analysis.duplicated.isEmpty)
        #expect(Set(analysis.atRisk.map(\.name)) == ["Japan", "Norway"])
    }

    @Test("The scanner actually records file prints")
    func scannerStoresPrints() async throws {
        // End-to-end: scan a real folder tree, confirm filePrints landed so
        // content matching has something to work with after a rescan.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dm-prints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Trip"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2048).write(to: root.appending(path: "Trip/a.raw"))
        try Data(repeating: 2, count: 4096).write(to: root.appending(path: "Trip/b.raw"))
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "P", name: "P")
        try await Scanner(store: store).scan(volumeURL: root, driveId: drive.id!)

        let blob: Data? = try await store.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT filePrints FROM folder WHERE path = 'Trip'")?["filePrints"]
        }
        let prints = try #require(blob.map(FilePrint.unpack))
        #expect(prints.count == 2, "two files fingerprinted directly in Trip")
        #expect(prints.contains(FilePrint.of(name: "a.raw", size: 2048)))
        #expect(prints.contains(FilePrint.of(name: "b.raw", size: 4096)))
    }
}

@Suite("Rescan detection")
struct RescanDetectionTests {
    private let gb: Int64 = 1_000_000_000

    @Test("A sizable folder with files but no prints flags its drive for rescan")
    func flagsPrintlessDrive() throws {
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "Old", name: "Old")
        try store.dbWriter.write { db in
            var root = Folder(driveId: drive.id!, name: "Old", path: "", depth: 0)
            try root.insert(db)
            // Big folder, has files, but filePrints stays NULL (pre-v5 scan).
            var f = Folder(driveId: drive.id!, parentId: root.id!, name: "Photos",
                           path: "Photos", depth: 1,
                           totalBytes: 50 * gb, totalFileCount: 500)
            try f.insert(db)
        }
        let analysis = try store.analyseCopies()
        #expect(analysis.drivesNeedingRescan == ["Old"])
        // Crucially, it does NOT report the folder as safely single-copy —
        // there's simply no data, and the banner says so.
        #expect(analysis.atRisk.isEmpty)
    }

    @Test("Fully fingerprinted drives don't flag for rescan")
    func noFlagWhenPrintsPresent() throws {
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "New", name: "New")
        try store.dbWriter.write { db in
            var root = Folder(driveId: drive.id!, name: "New", path: "", depth: 0)
            try root.insert(db)
            var f = Folder(driveId: drive.id!, parentId: root.id!, name: "Photos",
                           path: "Photos", depth: 1, totalBytes: 50 * gb, totalFileCount: 500)
            try f.insert(db)
            let prints = Set((0..<500).map { FilePrint.of(name: "f\($0)", size: 1000) })
            try db.execute(sql: "UPDATE folder SET filePrints = ? WHERE id = ?",
                           arguments: [FilePrint.pack(prints), f.id!])
            try db.execute(sql: "UPDATE drive SET contentScanned = 1 WHERE id = ?", arguments: [drive.id!])
        }
        #expect(try store.analyseCopies().drivesNeedingRescan.isEmpty)
    }
}

@Suite("Rescan flag regression")
struct RescanFlagRegressionTests {
    private let gb: Int64 = 1_000_000_000

    @Test("A scanned drive with bundles and nested-only folders is NOT flagged")
    func scannedDriveWithPrintlessFoldersNotFlagged() throws {
        // The bug: leaf bundles (.fcpbundle) and folders whose files are all in
        // subfolders legitimately have no own-prints. A per-folder "files but no
        // prints" check flagged such drives forever, even right after a scan.
        let store = try Store()
        let drive = try store.recordSighting(volumeUUID: "D", name: "D")
        try store.dbWriter.write { db in
            // The scanner marks this on completion.
            try db.execute(sql: "UPDATE drive SET contentScanned = 1 WHERE id = ?", arguments: [drive.id!])

            var root = Folder(driveId: drive.id!, name: "D", path: "", depth: 0)
            try root.insert(db)

            // A leaf bundle: sized, file-count > 0, deliberately no prints.
            var bundle = Folder(driveId: drive.id!, parentId: root.id!, name: "Project.fcpbundle",
                                path: "Project.fcpbundle", depth: 1,
                                ownBytes: 50 * gb, totalBytes: 50 * gb,
                                ownFileCount: 800, totalFileCount: 800, isLeafBundle: true)
            try bundle.insert(db)

            // A container folder whose files live in a subfolder (no own-prints).
            var album = Folder(driveId: drive.id!, parentId: root.id!, name: "Album",
                               path: "Album", depth: 1, totalBytes: 30 * gb, totalFileCount: 700)
            try album.insert(db)
            var inner = Folder(driveId: drive.id!, parentId: album.id!, name: "Raw",
                               path: "Album/Raw", depth: 2,
                               ownBytes: 30 * gb, totalBytes: 30 * gb,
                               ownFileCount: 700, totalFileCount: 700)
            try inner.insert(db)
            let prints = Set((0..<700).map { FilePrint.of(name: "r\($0)", size: 1000) })
            try db.execute(sql: "UPDATE folder SET filePrints = ? WHERE id = ?",
                           arguments: [FilePrint.pack(prints), inner.id!])
        }

        // Bundle and Album have no own-prints, but the drive WAS scanned — so no
        // rescan should be demanded.
        #expect(try store.analyseCopies().drivesNeedingRescan.isEmpty)
    }
}
