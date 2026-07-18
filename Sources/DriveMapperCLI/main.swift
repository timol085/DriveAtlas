import Foundation
import DriveMapperCore

// A thin harness over DriveMapperCore so the scanner and catalog can be driven
// without a UI. Useful for calibrating scan times on real drives and for
// checking what actually landed in the database.

func usage() -> Never {
    print("""
    driveatlas — external drive catalog

      scan <path> [name]   Scan a volume or folder into the catalog
      watch                Watch for drives being plugged in and scan them
      volumes              Show mounted volumes and whether they'd be catalogued
      drives               List catalogued drives
      backup               What's on only one drive, and what's duplicated
      tree <name> [depth]  Print a drive's folder tree (default depth 2)
      search <query>       Search folder names across all drives
      db                   Show the catalog file path and size

    Catalog lives at ~/Library/Application Support/DriveAtlas/catalog.sqlite
    """)
    exit(1)
}

func humanBytes(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

let storeURL = try Store.defaultURL()
let store = try Store(url: storeURL)

switch command {

case "scan":
    guard args.count >= 2 else { usage() }
    let path = (args[1] as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        print("Not a directory: \(url.path)")
        exit(1)
    }

    let name = args.count >= 3 ? args[2] : url.lastPathComponent
    // Identify by real volume UUID when scanning an actual mount; fall back to the
    // path so scanning an arbitrary folder still works for testing.
    let volumeUUID = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        ?? "path:\(url.path)"
    let volumeCreated = try? url.resourceValues(forKeys: [.volumeCreationDateKey]).volumeCreationDate

    let drive = try store.recordSighting(
        volumeUUID: volumeUUID,
        name: name,
        totalBytes: (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).map(Int64.init) ?? nil,
        volumeCreatedAt: volumeCreated
    )

    print("Scanning \(url.path) as \"\(name)\"…")
    let scanner = Scanner(store: store)
    let progress = ProgressPrinter()
    let summary = try await scanner.scan(
        volumeURL: url, driveId: drive.id!, rootName: name
    ) { p in
        progress.report(p.foldersScanned, p.currentPath)
    }
    progress.finish()

    print("""

    Done in \(String(format: "%.2f", summary.duration))s
      folders: \(summary.folderCount)
      files:   \(summary.fileCount)
      size:    \(humanBytes(summary.totalBytes))
      rate:    \(Int(Double(summary.folderCount) / max(summary.duration, 0.001))) folders/sec
    """)

case "volumes":
    // Diagnostic: shows every mounted volume and why it was or wasn't accepted.
    // This is how you check the disk-image filter is doing its job.
    // Deliberately does NOT pass .skipHiddenVolumes — as a diagnostic it should
    // show everything mounted, including the hidden disk images that the real
    // watcher never sees, so you can confirm they'd be rejected anyway.
    let keys: [URLResourceKey] = [.volumeIsEjectableKey]
    let urls = FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys, options: []
    ) ?? []
    for url in urls {
        guard let meta = try? DriveMetadata.read(volumeURL: url) else {
            print("?  \(url.path)  (diskutil failed)")
            continue
        }
        let verdict: String
        if meta.isDiskImage { verdict = "skip — disk image" }
        else if meta.isInternal { verdict = "skip — internal" }
        else if !meta.isEjectable { verdict = "skip — not ejectable" }
        else { verdict = "CATALOG" }

        let ssd: String
        switch meta.isSolidState {
        case true: ssd = "SSD"
        case false: ssd = "HDD"
        case nil: ssd = "type unknown"
        }
        print("\(verdict.padding(toLength: 22, withPad: " ", startingAt: 0))  \(meta.volumeName)  [\(meta.busProtocol ?? "?"), \(ssd)]")
    }

case "watch":
    let catalog = await DriveCatalog(store: store)
    print("Watching for drives… (ctrl-C to stop)")
    await catalog.start { activity in
        switch activity {
        case .driveConnected(let name, let known):
            print("→ connected: \(name)\(known ? " (known)" : " (new)")")
        case .scanStarted(let name):
            print("  scanning \(name)…")
        case .scanProgress:
            break  // too chatty for a log; the GUI shows this live
        case .scanFinished(let name, let summary):
            print("  \(name): \(summary.folderCount) folders, \(humanBytes(summary.totalBytes)) in \(String(format: "%.1f", summary.duration))s")
        case .scanFailed(let name, let error):
            print("  \(name) FAILED: \(error)")
        case .driveDisconnected(let path):
            print("← disconnected: \(path)")
        }
    }
    runForever()

case "backup":
    let analysis = try store.analyseCopies()

    print("Matching is by folder name and size — nothing reads file contents.")
    print("Treat a match as 'worth checking', not a verified backup.\n")

    if analysis.atRisk.isEmpty {
        print("Nothing large sits on only one drive.")
    } else {
        print("ONLY ONE COPY  (\(humanBytes(analysis.atRiskBytes)) total)")
        for group in analysis.atRisk.prefix(20) {
            let location = group.locations[0]
            print("  \(humanBytes(group.representativeBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(location.driveName)  \(location.path)")
        }
        if analysis.atRisk.count > 20 {
            print("  …and \(analysis.atRisk.count - 20) more")
        }
    }

    print()
    if analysis.duplicated.isEmpty {
        print("No duplicated folders found across drives.")
    } else {
        print("ON SEVERAL DRIVES  (\(humanBytes(analysis.reclaimableBytes)) reclaimable)")
        for group in analysis.duplicated.prefix(20) {
            print("  \(humanBytes(group.representativeBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(group.name)  ×\(group.driveCount)  [\(group.driveNames.joined(separator: ", "))]")
        }
    }

case "drives":
    let drives = try store.allDrives()
    if drives.isEmpty { print("No drives catalogued yet. Try: driveatlas scan <path>") }
    for d in drives {
        let kind: String
        switch d.isSolidState {
        case true: kind = "SSD"
        case false: kind = "HDD"
        case nil: kind = "unknown"
        }
        let size = d.totalBytes.map(humanBytes) ?? "?"
        let scanned = d.lastScannedAt.map { "scanned \(relative($0))" } ?? "never scanned"

        // A ten-cell bar is enough to see "full" at a glance without a GUI.
        let capacity: String
        if let fraction = d.usedFraction, let free = d.freeBytes {
            let filled = Int((fraction * 10).rounded())
            let bar = String(repeating: "█", count: filled)
                + String(repeating: "░", count: 10 - filled)
            capacity = "  \(bar) \(humanBytes(free)) free"
        } else {
            capacity = "  (free space unknown — reconnect to measure)"
        }

        print("\(d.name)  [\(kind), \(size)]  \(scanned)\(capacity)")
    }

case "tree":
    guard args.count >= 2 else { usage() }
    let maxDepth = args.count >= 3 ? Int(args[2]) ?? 2 : 2
    guard let drive = try store.allDrives().first(where: { $0.name == args[1] }) else {
        print("No drive named \"\(args[1])\". Known: \(try store.allDrives().map(\.name).joined(separator: ", "))")
        exit(1)
    }
    guard let root = try store.rootFolder(driveId: drive.id!) else {
        print("\(drive.name) has not been scanned yet.")
        exit(1)
    }
    print("\(drive.name)  (\(humanBytes(root.totalBytes)))")
    try printTree(store: store, folder: root, prefix: "", maxDepth: maxDepth)

case "search":
    guard args.count >= 2 else { usage() }
    let query = args[1...].joined(separator: " ")
    let hits = try store.searchFolders(query)
    if hits.isEmpty { print("No matches for \"\(query)\"") }

    // Show which drive each hit is on — that's the entire point of the app.
    let drives = try store.allDrives()
    let byId = Dictionary(uniqueKeysWithValues: drives.compactMap { d in d.id.map { ($0, d) } })
    for hit in hits.prefix(40) {
        let driveName = byId[hit.driveId]?.name ?? "?"
        let where_ = hit.path.isEmpty ? "/" : hit.path
        print("\(driveName.padding(toLength: 16, withPad: " ", startingAt: 0))  \(where_)  (\(humanBytes(hit.totalBytes)))")
    }

case "debug":
    // Posts a command to the running app's DebugBridge. Development tool: lets
    // the app be driven and photographed without screen-capture permission.
    guard args.count >= 2 else { usage() }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.driveatlas.debug"),
        object: args[1],
        userInfo: nil,
        deliverImmediately: true
    )
    // Give the notification time to deliver before the process exits.
    try? await Task.sleep(nanoseconds: 300_000_000)

case "db":
    let size = (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.size] as? Int64) ?? 0
    print("\(storeURL.path)  (\(humanBytes(size ?? 0)))")

default:
    usage()
}

// MARK: - Helpers

func printTree(store: Store, folder: Folder, prefix: String, maxDepth: Int) throws {
    guard folder.depth < maxDepth else { return }
    let children = try store.children(of: folder.id!)
    for (i, child) in children.enumerated() {
        let isLast = i == children.count - 1
        let branch = isLast ? "└── " : "├── "

        // The hover-tooltip content, rendered inline: what file types live below here.
        let exts = try store.extensions(of: child.id!, rollup: true).prefix(3)
        let extSummary = exts.isEmpty
            ? ""
            : "  " + exts.map { "\($0.rollCount) .\($0.ext.isEmpty ? "—" : $0.ext)" }.joined(separator: ", ")

        let marker = child.isLeafBundle ? " ⏹" : ""
        print("\(prefix)\(branch)\(child.name)\(marker)  \(humanBytes(child.totalBytes))\(extSummary)")

        try printTree(
            store: store, folder: child,
            prefix: prefix + (isLast ? "    " : "│   "),
            maxDepth: maxDepth
        )
    }
}

/// Parks the process on the main run loop so NSWorkspace keeps delivering mount
/// notifications.
///
/// This exists as a separate synchronous function because everything at
/// main.swift's top level is an async context once you `await` anywhere in it,
/// and `RunLoop.run()` is unavailable from async contexts.
func runForever() -> Never {
    RunLoop.main.run()
    // RunLoop.run() only returns if no sources are registered at all.
    exit(0)
}

func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
}

/// Overwrites a single terminal line so a long scan shows live progress.
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPrint = Date.distantPast

    func report(_ count: Int, _ path: String) {
        lock.lock()
        defer { lock.unlock() }
        // Throttle: printing every folder would dominate the scan time itself.
        guard Date().timeIntervalSince(lastPrint) > 0.1 else { return }
        lastPrint = Date()
        let short = path.count > 60 ? "…" + path.suffix(59) : path
        FileHandle.standardError.write("\r\u{1B}[K  \(count) folders — \(short)".data(using: .utf8)!)
    }

    func finish() {
        FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!)
    }
}
