import AppKit
import SwiftUI
import DriveMapperCore

/// Transient state for the quick-search panel.
///
/// Deliberately separate from `AppModel`: this is UI-only state for a
/// throwaway search box, not something the rest of the app needs to know
/// about, and keeping it here means opening the panel never touches (or gets
/// confused with) the search field in the main window.
@Observable
@MainActor
final class QuickSearchState {
    var query: String = "" {
        didSet { selectedIndex = 0 }   // a new query invalidates the old selection
    }
    var results: [AppModel.SearchHit] = []
    /// Bumped every time the panel is shown, purely to give SwiftUI's
    /// `.onChange` something to fire on so the text field can re-claim focus —
    /// `.onAppear` only runs once, since the panel and its hosting view stay
    /// alive between show/hide rather than being recreated.
    var showToken: Int = 0

    /// Highlighted row. Indexes into whichever list is showing — results when
    /// there's a query, the drive list when there isn't.
    var selectedIndex: Int = 0

    func moveSelection(by delta: Int, count: Int) {
        guard count > 0 else { return }
        // Clamps rather than wraps: wrapping from the last result back to the
        // first is disorienting when you're holding ↓ to scan a list.
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }
}

/// Borderless, non-activating floating panel — the Spotlight/Alfred pattern.
/// `.nonactivatingPanel` is what lets it become key (so the text field can
/// receive typing) without bringing DriveAtlas to the front or bouncing its
/// Dock icon; `canBecomeKey` is overridden because that's not automatic for a
/// borderless panel.
private final class QuickSearchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class QuickSearchController {
    private let state = QuickSearchState()
    private let model: AppModel
    private let onOpenFolder: (Int64) -> Void
    private let onOpenDrive: (Int64) -> Void
    private let onOpenMainWindow: () -> Void
    private var panel: QuickSearchWindow?
    private var resignObserver: NSObjectProtocol?

    init(
        model: AppModel,
        onOpenFolder: @escaping (Int64) -> Void,
        onOpenDrive: @escaping (Int64) -> Void,
        onOpenMainWindow: @escaping () -> Void
    ) {
        self.model = model
        self.onOpenFolder = onOpenFolder
        self.onOpenDrive = onOpenDrive
        self.onOpenMainWindow = onOpenMainWindow
        observeResultsForResize()
    }

    /// Whether the panel is currently on screen — lets a caller check state
    /// before deciding to show/hide rather than guess via `toggle()`.
    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        state.query = ""
        state.results = []
        state.showToken += 1

        resize(panel)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Current highlighted row, for tests.
    var selectedIndex: Int { state.selectedIndex }

    /// Moves the selection as an arrow key would, for tests.
    func moveSelection(by delta: Int) {
        let count = state.query.trimmingCharacters(in: .whitespaces).isEmpty
            ? model.drives.count
            : state.results.count
        state.moveSelection(by: delta, count: count)
    }

    /// Sets the query text directly — used by `DebugBridge` to drive a search
    /// without simulating keystrokes.
    func setQuery(_ text: String) {
        state.query = text
        state.results = model.search(text)
    }

    // MARK: - Panel

    private func makePanel() -> QuickSearchWindow {
        let view = QuickSearchView(
            state: state,
            model: model,
            onOpen: { [weak self] folderId in
                self?.onOpenFolder(folderId)
                self?.hide()
            },
            onOpenDrive: { [weak self] driveId in
                self?.onOpenDrive(driveId)
                self?.hide()
            },
            onOpenMainWindow: { [weak self] in
                self?.onOpenMainWindow()
                self?.hide()
            },
            onDismiss: { [weak self] in self?.hide() }
        )
        // The panel is its own window, so the main scene's `.tint` doesn't
        // reach it — it needs the app accent applied here as well.
        let hosting = NSHostingView(rootView: view.tint(AppColor.accent))

        let panel = QuickSearchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 64),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting

        // Click-away dismissal, the other half of the Spotlight/Alfred feel —
        // without this the panel just sits there after you've moved on.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.hide() }

        return panel
    }

    /// Centered on whichever screen the pointer is on, roughly a third of the
    /// way down — Spotlight's position, not coincidentally.
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }

        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - screen.frame.height * 0.32 - size.height
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    /// The panel grows and shrinks with the result list. `withObservationTracking`
    /// is the documented bridge from `@Observable` state into imperative code —
    /// each call fires once, so the callback re-subscribes itself every time.
    private func observeResultsForResize() {
        withObservationTracking {
            // Both: switching between the results list and the empty-query
            // drive list is itself a `results.count` change (down to zero), and
            // tracking `drives.count` too covers a scan completing while the
            // panel happens to be open.
            _ = state.results.count
            _ = model.drives.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                self.resize(panel)
                self.observeResultsForResize()
            }
        }
    }

    private func resize(_ panel: NSPanel) {
        guard let hosting = panel.contentView as? NSHostingView<QuickSearchView> else { return }
        let fitting = hosting.fittingSize
        let origin = panel.frame.origin
        // Keep the top edge fixed and grow downward — AppKit's y-axis points
        // up, so a naive setContentSize grows from the bottom and the search
        // field visibly jumps upward every time a result is added.
        let newFrame = NSRect(
            x: origin.x, y: origin.y + panel.frame.height - fitting.height,
            width: 560, height: fitting.height
        )
        panel.setFrame(newFrame, display: true)
    }
}

// MARK: - Content

/// Layout constants shared between the search field and the rows below it, so
/// the icon column lines up down the whole panel. Previously the field's icon
/// and the row icons were positioned independently and visibly disagreed.
private enum QS {
    static let width: CGFloat = 560
    static let hInset: CGFloat = 16
    static let iconColumn: CGFloat = 26
    static let iconGap: CGFloat = 10
    static let resultRowHeight: CGFloat = 52
    static let driveRowHeight: CGFloat = 40
    static let maxVisibleRows = 7
}

/// The single surface: search on top, and everything the old right-click menu
/// held now lives inside it too — the drive list fills the space when the
/// query is empty, and a "•••" menu in the footer carries Launch at Login and
/// Quit. One gesture opens this (click the icon, or ⌃⌥Space); there is nothing
/// else to discover.
private struct QuickSearchView: View {
    @Bindable var state: QuickSearchState
    let model: AppModel
    let onOpen: (Int64) -> Void
    let onOpenDrive: (Int64) -> Void
    let onOpenMainWindow: () -> Void
    let onDismiss: () -> Void

    @FocusState private var focused: Bool
    @State private var isLoginEnabled = false

    /// Last place the pointer was seen, and over which row. Hover only takes
    /// over the selection once the pointer has actually *moved* — otherwise
    /// showing the panel under a stationary cursor silently hijacked the
    /// selection, so ⌃⌥Space → type → Enter opened whatever happened to be
    /// under the mouse instead of the top hit.
    @State private var hoverAnchor: (index: Int, point: CGPoint)?

    /// How many rows the current mode is showing — the one number arrow keys,
    /// Enter, and the panel height all need to agree on.
    private var rowCount: Int {
        isSearching ? state.results.count : model.drives.count
    }

    private var isSearching: Bool {
        !state.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if rowCount > 0 || isSearching {
                Divider()
                rows
            }
            Divider()
            footer
        }
        .frame(width: QS.width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
        .onAppear {
            focused = true
            isLoginEnabled = LaunchAtLogin.isEnabled
        }
        .onChange(of: state.showToken) { _, _ in
            focused = true
            isLoginEnabled = LaunchAtLogin.isEnabled
            hoverAnchor = nil
        }
        // Arrow keys have to be intercepted before the text field turns them
        // into cursor movement, which is why these sit on the container and
        // return `.handled`.
        .onKeyPress(.upArrow) {
            state.moveSelection(by: -1, count: rowCount)
            return .handled
        }
        .onKeyPress(.downArrow) {
            state.moveSelection(by: 1, count: rowCount)
            return .handled
        }
        .onExitCommand(perform: onDismiss)
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: QS.iconGap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: QS.iconColumn)
            TextField("Search every drive…", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($focused)
                .onSubmit(openSelection)
                .onChange(of: state.query) { _, query in
                    state.results = model.search(query)
                    // New results appear under the cursor; same reasoning.
                    hoverAnchor = nil
                }
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                    state.results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, QS.hInset)
        .padding(.vertical, 13)
    }

    // MARK: Rows

    @ViewBuilder
    private var rows: some View {
        if isSearching && state.results.isEmpty {
            emptyMessage("No matches for “\(state.query)”")
        } else if !isSearching && model.drives.isEmpty {
            emptyMessage("No drives catalogued yet")
        } else {
            // ScrollView + LazyVStack rather than List: this needs a custom
            // selection highlight driven by arrow keys, and List's own
            // selection/separator styling fights that.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isSearching {
                            ForEach(Array(state.results.enumerated()), id: \.element.id) { index, hit in
                                QuickResultRow(hit: hit, isSelected: index == state.selectedIndex)
                                    // Namespaced by mode. A bare `.id(index)`
                                    // overrides SwiftUI's view identity, so
                                    // switching between the drive list and the
                                    // results list reused row 0's *drive* view
                                    // for result 0 — the panel rendered four
                                    // drives and one folder under a "5 results"
                                    // footer.
                                    .id("r\(index)")
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(hit) }
                                    .onContinuousHover { phase in
                                        handleHover(phase, index: index)
                                    }
                            }
                        } else {
                            ForEach(Array(model.drives.enumerated()), id: \.element.id) { index, drive in
                                QuickDriveRow(drive: drive, isSelected: index == state.selectedIndex)
                                    .id("d\(index)")
                                    .contentShape(Rectangle())
                                    .onTapGesture { onOpenDrive(drive.id ?? -1) }
                                    .onContinuousHover { phase in
                                        handleHover(phase, index: index)
                                    }
                            }
                        }
                    }
                }
                .frame(height: listHeight)
                .onChange(of: state.selectedIndex) { _, index in
                    // Keeps keyboard selection visible when it moves past the
                    // bottom of the scroll view.
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(isSearching ? "r\(index)" : "d\(index)", anchor: .center)
                    }
                }
            }
        }
    }

    private var listHeight: CGFloat {
        let rowHeight = isSearching ? QS.resultRowHeight : QS.driveRowHeight
        return CGFloat(min(rowCount, QS.maxVisibleRows)) * rowHeight
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, QS.hInset)
            .padding(.vertical, 14)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            // Earns its row by teaching the keyboard interaction, rather than
            // being a strip of empty space holding one button.
            if rowCount > 0 {
                KeyHint(keys: "↑↓", label: "navigate")
                KeyHint(keys: "↵", label: isSearching ? "open" : "show")
                Text(isSearching
                     ? "\(state.results.count) result\(state.results.count == 1 ? "" : "s")"
                     : "\(model.drives.count) drives")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Toggle("Launch at Login", isOn: loginBinding)
                Divider()
                Button("Open DriveAtlas") { onOpenMainWindow() }
                Button("Quit DriveAtlas") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            // `.borderlessButton` draws a disclosure chevron next to the icon,
            // which looked like a rendering artefact. `.button` + no indicator
            // gives a plain icon that opens the menu.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, QS.hInset)
        .padding(.vertical, 8)
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { isLoginEnabled },
            set: { newValue in
                if let error = LaunchAtLogin.setEnabled(newValue) {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn't change Launch at Login"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
                isLoginEnabled = LaunchAtLogin.isEnabled
            }
        )
    }

    // MARK: Actions

    /// Moves the selection on genuine pointer movement only.
    ///
    /// A plain `.onHover` fires when a row appears *under* an already-stationary
    /// cursor, which is exactly what happens when the panel opens near the
    /// mouse. Comparing against the last seen row and point distinguishes "the
    /// user moved onto this row" from "this row materialised under the user".
    private func handleHover(_ phase: HoverPhase, index: Int) {
        guard case .active(let point) = phase else { return }
        defer { hoverAnchor = (index, point) }
        guard let anchor = hoverAnchor else { return }   // first sighting: not movement
        let movedRow = anchor.index != index
        let movedFar = hypot(point.x - anchor.point.x, point.y - anchor.point.y) > 3
        if movedRow || movedFar {
            state.selectedIndex = index
        }
    }

    /// Enter acts on the highlighted row, in whichever list is showing.
    private func openSelection() {
        if isSearching {
            guard state.results.indices.contains(state.selectedIndex) else { return }
            open(state.results[state.selectedIndex])
        } else {
            guard model.drives.indices.contains(state.selectedIndex) else { return }
            onOpenDrive(model.drives[state.selectedIndex].id ?? -1)
        }
    }

    private func open(_ hit: AppModel.SearchHit) {
        guard let id = hit.folder.id else { return }
        onOpen(id)
    }
}

/// A keycap + what it does, for the footer.
private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct QuickResultRow: View {
    let hit: AppModel.SearchHit
    let isSelected: Bool

    /// The parent path, or nothing when the folder sits at the drive root —
    /// showing "PortableSSD · Isa Examen" for a folder *named* Isa Examen just
    /// repeated the title back at you.
    private var parentPath: String? {
        let path = hit.folder.path
        guard !path.isEmpty, path != hit.folder.name else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    var body: some View {
        HStack(spacing: QS.iconGap) {
            Image(systemName: hit.folder.isLeafBundle ? "shippingbox.fill" : "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(AppColor.accent)
                .frame(width: QS.iconColumn)

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.folder.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    // The drive name leads — it's the answer to the question
                    // the whole app exists to answer.
                    Text(hit.driveName)
                        .foregroundStyle(AppColor.accent)
                    if let parentPath {
                        Text("·").foregroundStyle(Color.secondary.opacity(0.6))
                        Text(parentPath)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .font(.caption)
            }

            Spacer(minLength: 8)

            Text(formatBytes(hit.folder.totalBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, QS.hInset)
        .frame(height: QS.resultRowHeight)
        .background(selectionBackground(isSelected))
    }
}

private struct QuickDriveRow: View {
    let drive: Drive
    let isSelected: Bool

    var body: some View {
        HStack(spacing: QS.iconGap) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 15))
                .foregroundStyle(AppColor.accent)
                .frame(width: QS.iconColumn)

            Text(drive.name)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(drive.kindLabel)
                .font(.caption)
                .foregroundStyle(Color.secondary.opacity(0.7))
            if let total = drive.totalBytes {
                Text(formatBytes(total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    // Fixed width so the sizes form a column instead of
                    // ragging against each drive's name length.
                    .frame(width: 72, alignment: .trailing)
            }
        }
        .padding(.horizontal, QS.hInset)
        .frame(height: QS.driveRowHeight)
        .background(selectionBackground(isSelected))
    }
}

/// See `SelectionBackground` — shared with the sidebar so both surfaces show
/// selection identically.
@ViewBuilder
private func selectionBackground(_ isSelected: Bool) -> some View {
    SelectionBackground(isSelected: isSelected)
}
