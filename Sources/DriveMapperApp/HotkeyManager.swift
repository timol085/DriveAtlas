import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcut that opens the quick-search panel from anywhere —
/// mid-Finder, mid-Final-Cut, without switching to DriveAtlas first.
///
/// Default is ⌃⌥Space, chosen to avoid the two combos everyone already has
/// bound: ⌘Space is Spotlight, ⌥Space is Alfred's default.
///
/// ## Why Carbon, in 2026
///
/// This originally used `NSEvent.addGlobalMonitorForEvents`, and it did not
/// work — verified empirically: with Input Monitoring granted
/// (`CGPreflightListenEventAccess() == true`) the callback still never fired
/// from another app. That API is gated on **Accessibility** trust, not Input
/// Monitoring, because a global monitor can observe *every* keystroke you type
/// system-wide. macOS is right to gate it, and it's the wrong tool here.
///
/// `RegisterEventHotKey` registers one specific key combination with the
/// window server and fires only for that combination. It can't observe
/// anything else, so it needs **no permission at all** — no Accessibility, no
/// Input Monitoring, no prompt, and nothing that a rebuild's changed ad-hoc
/// signature can invalidate. It's the API behind essentially every menu bar
/// app's global shortcut, and it is not deprecated.
@MainActor
final class HotkeyManager {
    /// 49 (`kVK_Space`) is Space's virtual key code on every keyboard layout —
    /// a physical position, not a character.
    private let keyCode = UInt32(kVK_Space)
    /// Carbon's own modifier constants, not `NSEvent.ModifierFlags`.
    private let modifiers = UInt32(controlKey | optionKey)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onTrigger: () -> Void

    /// The Carbon callback is a C function pointer and can't capture context,
    /// so the live instance is reachable through this. Only one hotkey manager
    /// exists, which makes a single reference sufficient.
    private static weak var active: HotkeyManager?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        Self.active = self

        // Fires regardless of which app is frontmost.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                // Carbon dispatches this on the main run loop, so we're already
                // on the main actor — this asserts that rather than hopping,
                // which would delay the panel by a frame.
                MainActor.assumeIsolated {
                    HotkeyManager.active?.onTrigger()
                }
                return noErr
            },
            1, &eventType, nil, &eventHandler
        )

        var hotKeyID = EventHotKeyID(
            signature: OSType(0x44_41_54_4C),  // 'DATL'
            id: 1
        )
        RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )

        // No local NSEvent monitor alongside this. A registered hot key fires
        // whichever app is frontmost — DriveAtlas included — so pairing it with
        // a local monitor meant both fired when DriveAtlas was active,
        // `toggle()` ran twice, and the panel opened and instantly closed
        // again. Verified: with both installed the frontmost case failed while
        // the background case worked; with Carbon alone, both work.
    }

    func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
        if Self.active === self { Self.active = nil }
    }
}
