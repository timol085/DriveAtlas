import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` — the modern (macOS 13+) way to
/// register an app as a login item, replacing the old deprecated
/// helper-launcher approach.
///
/// Everything else in this app (the volume watcher catching a plug-in, the
/// Spotlight donations, the quick-search hotkey) only works while the process
/// is running. Without this, that's contingent on remembering to open the app
/// after every restart — this is what makes it actually ambient.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// - Important: `SMAppService` ties the registration to the exact bundle
    ///   path it was registered from. Running the debug build straight out of
    ///   the project directory works, but replacing that `.app` on the next
    ///   `make-app.sh` can leave a dangling or duplicate entry — the
    ///   guarantee is solid once the app is dragged to `/Applications` and
    ///   rebuilt in place stops happening.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }
}
