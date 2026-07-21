import AppKit
import DriveMapperCore

/// Owns the menu-bar icon via `NSStatusItem`.
///
/// Originally this split left-click (quick search) from right-click (a
/// traditional NSMenu with the drive list, Launch at Login, Quit) — but a
/// menu bar icon doing two different things depending on which mouse button
/// you use isn't a pattern anyone reaches for by instinct. Both click types
/// now do the same thing: open the quick-search panel. Everything the old
/// right-click menu held moved *into* that panel instead — the drive list
/// fills its empty-query state, and a small "•••" button carries Launch at
/// Login and Quit. One gesture, one surface, nothing hidden behind a
/// non-obvious click.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let quickSearch: QuickSearchController
    private var hotkey: HotkeyManager?

    init(model: AppModel) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.quickSearch = QuickSearchController(
            model: model,
            onOpenFolder: { folderId in
                model.reveal(folderId: folderId)
                StatusItemController.activateMainWindow()
            },
            onOpenDrive: { driveId in
                model.selection = .drive(driveId)
                model.searchQuery = ""
                StatusItemController.activateMainWindow()
            },
            onOpenMainWindow: {
                StatusItemController.activateMainWindow()
            }
        )

        if let button = statusItem.button {
            button.image = Self.statusImage(scanning: false)
            button.action = #selector(handleClick)
            button.target = self
            // Both mouse buttons route here now — see the note above.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Repaints the icon on scan start/stop. AppModel calls this after
        // every activity event rather than us polling.
        model.onActivityChanged = { [weak self] in self?.updateIcon(scanning: model.isScanningAnything) }

        let hotkey = HotkeyManager { [weak self] in self?.quickSearch.toggle() }
        hotkey.start()
        self.hotkey = hotkey

        DebugBridge.attachQuickSearch(quickSearch)
    }

    @objc private func handleClick() {
        quickSearch.toggle()
    }

    private func updateIcon(scanning: Bool) {
        statusItem.button?.image = Self.statusImage(scanning: scanning)
    }

    private static func statusImage(scanning: Bool) -> NSImage? {
        let name = scanning ? "externaldrive.badge.timemachine" : "externaldrive"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "DriveAtlas")
        // Template rendering is what makes a status-bar icon adapt to light
        // menu bars, dark menu bars, and the pressed state automatically — SF
        // Symbol images aren't template by default.
        image?.isTemplate = true
        return image
    }

    /// Brings the main window forward. Matched by "not a panel, real size"
    /// rather than a window identifier — SwiftUI doesn't document what it does
    /// with the id passed to `Window(_:id:)` at the AppKit level, so this
    /// avoids depending on that.
    static func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.frame.width > 300 }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
