import SwiftUI

/// The one definition of what "selected" looks like, shared by the sidebar and
/// the quick-search panel so the two can't drift apart.
///
/// A leading accent bar plus a light tint, rather than the filled highlight
/// macOS draws by default. The filled version measured 2.62:1 against the white
/// label text it forces — below WCAG AA's 4.5:1, and below even the 3:1
/// large-text floor. Tinting leaves every text colour in the row untouched, so
/// contrast stays whatever the surrounding view already guarantees, at any
/// system accent colour the user has set.
///
/// Full-bleed and square-edged on purpose: inset or rounded, the highlight
/// floats away from the row edges and stops reading as "this whole row".
struct SelectionBackground: View {
    let isSelected: Bool
    /// Sidebars get a hover cue as well; the panel drives hover through its own
    /// keyboard-aware selection instead.
    var isHovered: Bool = false

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(
                    isSelected
                        ? AppColor.accent.opacity(0.16)
                        : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                )
            if isSelected {
                Rectangle()
                    .fill(AppColor.accent)
                    .frame(width: 3)
            }
        }
    }
}
