import Foundation
import Testing
@testable import DriveMapperCore

/// The FSEvents plumbing itself needs a real mounted volume to exercise, but the
/// metadata-filtering decision — "is this a real content change or just macOS
/// housekeeping?" — is pure and worth pinning down, since a wrong answer either
/// flags every drive as stale forever or misses genuine edits.
@Suite("DriveChangeWatcher filter")
struct DriveChangeWatcherTests {

    @Test("A real file change fires")
    func realChangeFires() {
        #expect(DriveChangeWatcher.isRealChange(paths: ["/Volumes/Travel/Photos/2020"]))
    }

    @Test("Pure Spotlight/Trash housekeeping is ignored")
    func metadataOnlyIgnored() {
        #expect(!DriveChangeWatcher.isRealChange(paths: [
            "/Volumes/Travel/.Spotlight-V100/Store-V2",
            "/Volumes/Travel/.Trashes/501",
            "/Volumes/Travel/.fseventsd",
        ]))
    }

    @Test("A real change mixed in with housekeeping still fires")
    func mixedFires() {
        #expect(DriveChangeWatcher.isRealChange(paths: [
            "/Volumes/Travel/.Spotlight-V100/Store-V2",
            "/Volumes/Travel/Documents",
        ]))
    }

    @Test("An empty batch doesn't fire")
    func emptyDoesNotFire() {
        #expect(!DriveChangeWatcher.isRealChange(paths: []))
    }

    /// Exercises the real FSEvents stream on a temp directory: a genuine file
    /// write deep in the tree must reach the callback. This is the part the pure
    /// filter tests can't cover, and it's the whole reason we chose FSEvents —
    /// deep changes surface without walking. Slow (FSEvents latency), so it's the
    /// only integration test here.
    @Test("A real deep filesystem change reaches the callback")
    func realFSEventFires() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "fsev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appending(path: "a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let fired = FiredBox()
        let watcher = DriveChangeWatcher(volumePath: root.path) { fired.markFired() }
        watcher.start()
        defer { watcher.stop() }

        // Let the stream arm before mutating.
        try await Task.sleep(nanoseconds: 500_000_000)
        try Data("hello".utf8).write(to: deep.appending(path: "newfile.txt"))

        // FSEvents latency is 2s; poll up to 8s.
        for _ in 0..<80 {
            if fired.hasFired { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(fired.hasFired, "FSEvents should have reported the deep change")
    }
}

/// Thread-safe flag the FSEvents callback (background queue) can set and the test
/// can poll.
private final class FiredBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markFired() { lock.lock(); fired = true; lock.unlock() }
    var hasFired: Bool { lock.lock(); defer { lock.unlock() }; return fired }
}
