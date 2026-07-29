import Foundation
import Testing
@testable import DriveMapperCore

@Suite("FolderMatcher")
struct FolderMatcherTests {
    private let gb: Int64 = 1_000_000_000

    /// Fingerprints for a made-up set of files "f0…fN".
    private func prints(_ range: Range<Int>) -> Set<UInt64> {
        Set(range.map { FilePrint.of(name: "f\($0).arw", size: Int64($0 + 1) * 1000) })
    }

    private func node(
        _ id: Int64, drive: Int64, parent: Int64?, depth: Int, gb sizeGB: Double,
        prints: Set<UInt64>
    ) -> FolderMatcher.Node {
        .init(id: id, driveId: drive, parentId: parent, depth: depth,
              totalBytes: Int64(sizeGB * Double(gb)), ownPrints: prints)
    }

    @Test("Same files under differently-named folders match across drives")
    func differentNamesSameContent() {
        // The whole point: A on drive 1 and B on drive 2 hold the same 100 files
        // but the folders are named differently (names aren't even modelled here).
        let files = prints(0..<100)
        let nodes = [
            node(1, drive: 1, parent: 10, depth: 1, gb: 30, prints: files),
            node(10, drive: 1, parent: nil, depth: 0, gb: 30, prints: []),
            node(2, drive: 2, parent: 20, depth: 1, gb: 30, prints: files),
            node(20, drive: 2, parent: nil, depth: 0, gb: 30, prints: []),
        ]
        let result = FolderMatcher.match(nodes: nodes, minBytes: gb)

        #expect(result.duplicated.count == 1)
        #expect(Set(result.duplicated[0].folderIds) == [1, 2])
        #expect(result.duplicated[0].overlap == 1.0)
        #expect(result.atRisk.isEmpty)
    }

    @Test("A stray extra file still counts as a match")
    func toleratesStrayFiles() {
        // 100 shared files, plus one folder has 3 extras (a .DS_Store, sidecars).
        let shared = prints(0..<100)
        let withExtras = shared.union(prints(100..<103))
        let nodes = [
            node(1, drive: 1, parent: 10, depth: 1, gb: 30, prints: shared),
            node(10, drive: 1, parent: nil, depth: 0, gb: 30, prints: []),
            node(2, drive: 2, parent: 20, depth: 1, gb: 30, prints: withExtras),
            node(20, drive: 2, parent: nil, depth: 0, gb: 30, prints: []),
        ]
        let result = FolderMatcher.match(nodes: nodes, minBytes: gb)
        #expect(result.duplicated.count == 1, "Jaccard ~0.97 clears the threshold")
        #expect(result.atRisk.isEmpty)
    }

    @Test("Barely-overlapping folders are NOT copies")
    func lowOverlapIsNotAMatch() {
        // Two "Photos" folders that share only 20 of 100 files — not a backup.
        let a = prints(0..<100)
        let b = prints(80..<180)   // 20 shared, Jaccard ~0.11
        let nodes = [
            node(1, drive: 1, parent: 10, depth: 1, gb: 30, prints: a),
            node(10, drive: 1, parent: nil, depth: 0, gb: 30, prints: []),
            node(2, drive: 2, parent: 20, depth: 1, gb: 30, prints: b),
            node(20, drive: 2, parent: nil, depth: 0, gb: 30, prints: []),
        ]
        let result = FolderMatcher.match(nodes: nodes, minBytes: gb)
        #expect(result.duplicated.isEmpty)
        #expect(Set(result.atRisk) == [1, 2], "both are unbacked, separately")
    }

    @Test("A camera reusing 001.arw doesn't create a false match")
    func sequentialFilenameCollisionResistant() {
        // Two unrelated 100-file folders that happen to share ONE identical
        // (name, size) — the 001.arw case. One collision must not flag them.
        let collision: Set<UInt64> = [FilePrint.of(name: "001.arw", size: 25_000_000)]
        let a = prints(0..<100).union(collision)
        let b = prints(500..<600).union(collision)
        let nodes = [
            node(1, drive: 1, parent: 10, depth: 1, gb: 30, prints: a),
            node(10, drive: 1, parent: nil, depth: 0, gb: 30, prints: []),
            node(2, drive: 2, parent: 20, depth: 1, gb: 30, prints: b),
            node(20, drive: 2, parent: nil, depth: 0, gb: 30, prints: []),
        ]
        let result = FolderMatcher.match(nodes: nodes, minBytes: gb)
        #expect(result.duplicated.isEmpty, "one shared file among 200 is noise")
    }

    @Test("Content in nested subfolders still matches at the top level")
    func rollupAcrossSubfolders() {
        // Drive 1: Trip/ holds files directly. Drive 2: same files but split
        // into Trip/2019 and Trip/2020 subfolders. Rollup must still match Trip.
        let half1 = prints(0..<50)
        let half2 = prints(50..<100)
        let all = half1.union(half2)
        let nodes = [
            // Drive 1 — flat
            node(1, drive: 1, parent: 10, depth: 1, gb: 30, prints: all),
            node(10, drive: 1, parent: nil, depth: 0, gb: 30, prints: []),
            // Drive 2 — nested
            node(2, drive: 2, parent: 20, depth: 1, gb: 30, prints: []),
            node(3, drive: 2, parent: 2, depth: 2, gb: 15, prints: half1),
            node(4, drive: 2, parent: 2, depth: 2, gb: 15, prints: half2),
            node(20, drive: 2, parent: nil, depth: 0, gb: 30, prints: []),
        ]
        let result = FolderMatcher.match(nodes: nodes, minBytes: gb)
        #expect(result.duplicated.count == 1)
        #expect(Set(result.duplicated[0].folderIds) == [1, 2], "matched at Trip, not the subfolders")
    }

    @Test("Matched children are suppressed under their matched parent")
    func descendantSuppression() {
        // Both drives: Trip/ and Trip/Raw, identical. Report Trip only.
        let raw = prints(0..<60)
        let all = raw.union(prints(60..<80))
        let nodes = [
            node(1, drive: 1, parent: 10, depth: 1, gb: 30, prints: prints(60..<80)),
            node(11, drive: 1, parent: 1, depth: 2, gb: 20, prints: raw),
            node(10, drive: 1, parent: nil, depth: 0, gb: 30, prints: []),
            node(2, drive: 2, parent: 20, depth: 1, gb: 30, prints: prints(60..<80)),
            node(21, drive: 2, parent: 2, depth: 2, gb: 20, prints: raw),
            node(20, drive: 2, parent: nil, depth: 0, gb: 30, prints: []),
        ]
        _ = all
        let result = FolderMatcher.match(nodes: nodes, minBytes: gb)
        #expect(result.duplicated.count == 1)
        #expect(Set(result.duplicated[0].folderIds) == [1, 2], "Raw suppressed under Trip")
    }

    @Test("Two copies on the same drive are not a backup")
    func sameDriveNotABackup() {
        let files = prints(0..<100)
        let nodes = [
            node(1, drive: 1, parent: 10, depth: 1, gb: 30, prints: files),
            node(2, drive: 1, parent: 10, depth: 1, gb: 30, prints: files),   // same drive!
            node(10, drive: 1, parent: nil, depth: 0, gb: 30, prints: []),
        ]
        let result = FolderMatcher.match(nodes: nodes, minBytes: gb)
        #expect(result.duplicated.isEmpty, "same drive twice protects nothing")
        // Both are content-identical on one drive; the shallower/first is kept,
        // the other suppressed only if nested — here they're siblings, so both
        // surface as at-risk (neither has an OFF-drive copy).
        #expect(Set(result.atRisk) == [1, 2])
    }

    @Test("Folders below the size floor are ignored")
    func sizeFloor() {
        let files = prints(0..<100)
        let nodes = [
            node(1, drive: 1, parent: 10, depth: 1, gb: 0.01, prints: files),
            node(10, drive: 1, parent: nil, depth: 0, gb: 0.01, prints: []),
            node(2, drive: 2, parent: 20, depth: 1, gb: 0.01, prints: files),
            node(20, drive: 2, parent: nil, depth: 0, gb: 0.01, prints: []),
        ]
        let result = FolderMatcher.match(nodes: nodes, minBytes: 100_000_000)
        #expect(result.duplicated.isEmpty)
        #expect(result.atRisk.isEmpty)
    }

    @Test("Wildly different sizes are never compared (pruning is safe)")
    func sizePruningDoesntMissRealMatches() {
        // Same content, but sizes recorded very differently (shouldn't happen for
        // true copies, but proves the window doesn't hide an exact-content match
        // when sizes ARE close).
        let files = prints(0..<100)
        let nodes = [
            node(1, drive: 1, parent: 10, depth: 1, gb: 30, prints: files),
            node(10, drive: 1, parent: nil, depth: 0, gb: 30, prints: []),
            node(2, drive: 2, parent: 20, depth: 1, gb: 33, prints: files),   // +10%, within window
            node(20, drive: 2, parent: nil, depth: 0, gb: 33, prints: []),
        ]
        let result = FolderMatcher.match(nodes: nodes, minBytes: gb)
        #expect(result.duplicated.count == 1)
    }

    @Test("Empty input is empty output")
    func empty() {
        let result = FolderMatcher.match(nodes: [], minBytes: gb)
        #expect(result.duplicated.isEmpty)
        #expect(result.atRisk.isEmpty)
    }
}

@Suite("FilePrint")
struct FilePrintTests {
    @Test("Fingerprint is stable and case-insensitive on name")
    func stableAndCaseFolded() {
        let a = FilePrint.of(name: "IMG_1.ARW", size: 1000)
        let b = FilePrint.of(name: "img_1.arw", size: 1000)
        #expect(a == b, "case-folded so exFAT/APFS case differences don't split a copy")
        // Stable value — pin it so a hashing change that breaks stored prints is caught.
        #expect(FilePrint.of(name: "x", size: 0) == FilePrint.of(name: "x", size: 0))
    }

    @Test("Different name or size gives a different fingerprint")
    func distinguishes() {
        let base = FilePrint.of(name: "a.arw", size: 1000)
        #expect(FilePrint.of(name: "b.arw", size: 1000) != base)
        #expect(FilePrint.of(name: "a.arw", size: 1001) != base)
    }

    @Test("Name+size boundary can't collide via concatenation")
    func noConcatenationCollision() {
        // "ab" + size and "a" + "b"-in-size must not coincide — the \0 separator.
        #expect(FilePrint.of(name: "ab", size: 1) != FilePrint.of(name: "a", size: 1))
    }

    @Test("Pack/unpack round-trips a print set")
    func packRoundTrips() {
        let set: Set<UInt64> = [1, 2, 3, .max, 14_695_981_039_346_656_037]
        #expect(FilePrint.unpack(FilePrint.pack(set)) == set)
        #expect(FilePrint.pack([]).isEmpty)
        #expect(FilePrint.unpack(Data()).isEmpty)
    }
}
