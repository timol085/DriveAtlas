import Foundation
import Testing
@testable import DriveMapperCore

/// The debounced auto-rescan: a burst of changes must collapse to a single
/// rescan once the drive goes quiet, and a change during the wait must push the
/// rescan back rather than firing an extra one. Exercised through the injectable
/// interval + action so no real mounted volume is needed.
@Suite("DriveCatalog auto-rescan")
@MainActor
struct DriveCatalogTests {

    /// Thread-safe counter the (main-actor) action increments; kept as a class so
    /// the closure captures a reference.
    final class Counter {
        private(set) var fires: [String] = []
        func record(_ uuid: String) { fires.append(uuid) }
    }

    private func makeCatalog(quiet: Duration) throws -> (DriveCatalog, Counter) {
        let catalog = DriveCatalog(store: try Store(), autoRescanQuietPeriod: quiet)
        let counter = Counter()
        catalog.autoRescanAction = { counter.record($0) }
        return (catalog, counter)
    }

    @Test("A burst of changes fires exactly one rescan")
    func burstCoalesces() async throws {
        let (catalog, counter) = try makeCatalog(quiet: .milliseconds(120))

        // Five rapid changes, each well inside the quiet window.
        for _ in 0..<5 {
            catalog.scheduleAutoRescan(volumeUUID: "UUID-1")
            try await Task.sleep(for: .milliseconds(20))
        }
        // Wait out the quiet period after the last change.
        try await Task.sleep(for: .milliseconds(250))

        #expect(counter.fires == ["UUID-1"], "burst should collapse to one rescan")
    }

    @Test("A late change pushes the rescan back instead of adding one")
    func lateChangeReschedules() async throws {
        let (catalog, counter) = try makeCatalog(quiet: .milliseconds(150))

        catalog.scheduleAutoRescan(volumeUUID: "UUID-1")
        try await Task.sleep(for: .milliseconds(100))     // not yet elapsed
        #expect(counter.fires.isEmpty, "shouldn't fire before the window closes")

        catalog.scheduleAutoRescan(volumeUUID: "UUID-1")  // resets the timer
        try await Task.sleep(for: .milliseconds(100))      // 200ms since first, 100ms since reset
        #expect(counter.fires.isEmpty, "reset should have pushed the deadline back")

        try await Task.sleep(for: .milliseconds(120))      // now past the reset deadline
        #expect(counter.fires == ["UUID-1"])
    }

    @Test("Two drives debounce independently")
    func perDriveIndependent() async throws {
        let (catalog, counter) = try makeCatalog(quiet: .milliseconds(100))

        catalog.scheduleAutoRescan(volumeUUID: "A")
        catalog.scheduleAutoRescan(volumeUUID: "B")
        try await Task.sleep(for: .milliseconds(200))

        #expect(counter.fires.sorted() == ["A", "B"])
    }
}
