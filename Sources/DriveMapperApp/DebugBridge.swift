import AppKit
import Foundation

/// Local-only debug remote control.
///
/// Exists because UI bugs kept being fixed from theory: the development terminal
/// has no Screen Recording permission, so nothing outside the app can capture its
/// window. An app rendering *its own* view hierarchy needs no permission at all —
/// so the app photographs itself on request, and the CLI (`driveatlas debug …`)
/// posts the requests via distributed notification.
///
/// Commands (notification object string):
///   select-backup   select Backup Check in the sidebar
///   select-drive    select the first drive
///   snap:<tag>      write PNGs of every visible window to
///                   ~/Library/Application Support/DriveAtlas/debug/
///
/// Snapshots go to a fixed directory only — the command carries a tag, never a
/// path, so no other local process can use this to write anywhere else.
@MainActor
enum DebugBridge {
    static let notificationName = Notification.Name("com.driveatlas.debug")

    private static weak var model: AppModel?
    private static var token: NSObjectProtocol?

    static func start(model: AppModel) {
        Self.model = model
        // The token must be retained or the observer silently unregisters.
        token = DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main
        ) { note in
            // Extract only the Sendable string before hopping actors.
            let command = note.object as? String ?? ""
            Task { @MainActor in handle(command) }
        }
    }

    private static func handle(_ command: String) {
        switch command {
        case "select-backup":
            model?.selection = .backupCheck
        case "select-drive":
            if let id = model?.drives.first?.id { model?.selection = .drive(id) }
        case let cmd where cmd.hasPrefix("mode:"):
            // Flips the List/Map/Sizes toggle; @AppStorage picks the change up.
            let mode = String(cmd.dropFirst("mode:".count))
            if ["list", "graph", "treemap"].contains(mode) {
                UserDefaults.standard.set(mode, forKey: "treeViewMode")
            }
        case "orient":
            // Flips the node map's growth direction, same as its toolbar button.
            let key = "graphHorizontal"
            UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        case let cmd where cmd.hasPrefix("snap:"):
            snapshot(tag: sanitize(String(cmd.dropFirst("snap:".count))))
        case let cmd where cmd.hasPrefix("dump:"):
            dumpHierarchy(tag: sanitize(String(cmd.dropFirst("dump:".count))))
        default:
            break
        }
    }

    private static func sanitize(_ raw: String) -> String {
        let tag = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return tag.isEmpty ? "untagged" : tag
    }

    /// Writes the window's view tree with frames. Snapshots wash out material
    /// backgrounds; frames don't lie about geometry.
    private static func dumpHierarchy(tag: String) {
        var out = ""
        for window in NSApp.windows where window.isVisible && window.frame.width > 300 {
            out += "window frame=\(window.frame) contentLayoutRect=\(window.contentLayoutRect)\n"
            out += "styleMask.fullSizeContentView=\(window.styleMask.contains(.fullSizeContentView))\n"
            out += "titlebarAppearsTransparent=\(window.titlebarAppearsTransparent)\n"
            if let contentView = window.contentView {
                out += "contentView.safeAreaInsets=\(contentView.safeAreaInsets)\n"
                dump(view: contentView, depth: 0, into: &out)
            }
            out += "\n"
        }
        try? out.write(
            to: debugDirectory().appending(path: "\(tag).txt"),
            atomically: true, encoding: .utf8
        )
    }

    private static func dump(view: NSView, depth: Int, into out: inout String) {
        guard depth < 26 else { return }
        let indent = String(repeating: "  ", count: depth)
        let name = String(describing: type(of: view))
        out += "\(indent)\(name) frame=\(view.frame)"
        if view.isHidden { out += " HIDDEN" }
        out += "\n"
        for sub in view.subviews {
            dump(view: sub, depth: depth + 1, into: &out)
        }
    }

    private static func debugDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/DriveAtlas/debug")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Renders each visible window — including its titlebar and toolbar, which is
    /// the part under investigation — via the frame view that wraps contentView.
    private static func snapshot(tag: String) {
        let dir = debugDirectory()

        for (index, window) in NSApp.windows.enumerated() {
            guard window.isVisible,
                  window.frame.width > 300,   // skip status-item windows
                  let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
            else { continue }

            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appending(path: "\(tag)-\(index).png"))
        }
    }
}
