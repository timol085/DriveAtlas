import CoreSpotlight
import SwiftUI
import DriveMapperCore

@main
struct DriveMapperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("DriveAtlas", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 700, minHeight: 440)
                // No window-level `.tint`: it cascaded onto the toolbar and
                // painted the action buttons (Sort, Rescan, Drive Info) in the
                // accent colour, when native toolbar action icons are
                // monochrome grey. Accent is applied surgically instead — only
                // to selection controls (the view-mode and tab pickers) — since
                // everything semantic (selection highlights, warnings, icons)
                // already uses AppColor explicitly rather than the ambient tint.
                .task {
                    model.start()
                    // The delegate exists before this `.task` runs, but `model`
                    // doesn't exist until the App struct's @State is set up —
                    // this is the first point both are guaranteed to be ready.
                    appDelegate.attach(model: model)
                }
                // Clicking one of our donated Spotlight results lands here with
                // the item's identifier; jump straight to that folder.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard
                        let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                        let folderId = SpotlightIndexer.folderId(fromIdentifier: identifier)
                    else { return }
                    model.reveal(folderId: folderId)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 980, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // No MenuBarExtra scene: the menu-bar icon, its click routing, the
        // quick-search panel, and the global hotkey are all owned by
        // `StatusItemController` via the AppDelegate below. `MenuBarExtra` can
        // show a menu OR run a click action, not one depending on which mouse
        // button — and left/right doing different things is the entire
        // feature, so this drops to AppKit on purpose.
    }
}

/// Exists to bridge SwiftUI's `@State private var model` into AppKit's
/// `NSStatusItem` world, which SwiftUI's scene system doesn't otherwise reach.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    /// Idempotent: the `.task` that calls this can in principle run more than
    /// once (window close/reopen), but the status item must only be created once.
    @MainActor
    func attach(model: AppModel) {
        guard statusItemController == nil else { return }
        statusItemController = StatusItemController(model: model)
    }
}
