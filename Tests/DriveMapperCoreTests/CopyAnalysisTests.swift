import Foundation
import GRDB
import Testing
@testable import DriveMapperCore

@Suite("CopyAnalysis")
struct CopyAnalysisTests {

    private let gb: Int64 = 1_000_000_000

    /// Builds a store with drives and folders, sized in GB.
    private func makeStore(
        _ layout: [(drive: String, folders: [(path: String, gb: Double)])]
    ) throws -> Store {
        let store = try Store()
        for entry in layout {
            let drive = try store.recordSighting(volumeUUID: entry.drive, name: entry.drive)
            let driveId = drive.id!
            try store.dbWriter.write { db in
                // Every drive needs a root; analysis must ignore it.
                var root = Folder(driveId: driveId, name: entry.drive, path: "", depth: 0)
                try root.insert(db)

                for folder in entry.folders {
                    let components = folder.path.split(separator: "/")
                    var f = Folder(
                        driveId: driveId,
                        name: String(components.last ?? ""),
                        path: folder.path,
                        depth: components.count,
                        totalBytes: Int64(folder.gb * Double(self.gb)),
                        totalFileCount: 10
                    )
                    try f.insert(db)
                }
            }
        }
        return store
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
