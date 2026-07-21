import AppKit
import SwiftUI

/// DriveAtlas's own colours, deliberately **not** the system accent.
///
/// The app used to inherit `Color.accentColor`, which meant its identity colour
/// was whatever the user had set in System Settings. That isn't just a
/// consistency problem — it broke meaning. With an orange system accent,
/// "selected" and "this drive is nearly full" rendered as the same colour, so
/// two unrelated ideas became indistinguishable; with a blue accent they
/// separated again. Which meanings collide changed per machine, which is not a
/// thing a UI can be designed around.
///
/// So the two roles are pinned and verified distinct: accent ΔE 24.7 (protan)
/// / 33.6 (normal vision) from warning in light mode, 26.8 / 31.8 in dark.
/// Nothing a user picks can collapse them.
enum AppColor {

    /// Interactive and identity: selection, links, icons, breadcrumbs, the
    /// capacity bar's normal state.
    static let accent = dynamic(light: 0x2A78D6, dark: 0x3987E5)

    /// Caution, and nothing else: a nearly-full drive, an ageing SSD, folders
    /// with no second copy. Never used decoratively — if it's this colour,
    /// something wants attention.
    static let warning = dynamic(light: 0xC2540F, dark: 0xE07B3C)

    /// Both values are validated against their own mode's surface, rather than
    /// one colour being auto-lightened for dark mode — a flipped colour is
    /// rarely the right one.
    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(rgb: dark)
                : NSColor(rgb: light)
        })
    }
}
