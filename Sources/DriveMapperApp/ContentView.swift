import SwiftUI
import DriveMapperCore

/// The whole window.
///
/// Title, subtitle, inspector and toolbar are all declared **here**, once, rather
/// than inside each detail view. They're window-level chrome: `.inspector` is a
/// third column of the split view, and a toolbar declared on a detail view still
/// belongs to the window. Letting each selection bring its own meant the split
/// view restructured from three columns to two and back as you clicked around —
/// which shifted the sidebar out of reach and left stale rendering behind.
/// The detail views below are pure content.
struct ContentView: View {
    @Bindable var model: AppModel

    @AppStorage("treeViewMode") private var mode: TreeViewMode = .list
    @AppStorage("folderSort") private var sort: FolderSort = .name
    @AppStorage("folderSortAscending") private var ascending = true
    @State private var showInspector = false

    var body: some View {
        NavigationSplitView {
            DriveSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            // The Drive Info panel is a trailing panel INSIDE the detail area,
            // not a `.inspector` column. `.inspector` always shares the window
            // toolbar, so it drew up alongside the search field. As a panel
            // within the content it starts at the detail's top edge — level with
            // the drive breadcrumb row — and never touches the toolbar/search.
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector, model.selectedDrive != nil {
                    Divider()
                    inspectorContent
                        .frame(width: 300)
                        .transition(.move(edge: .trailing))
                }
            }
            .navigationTitle(navigationTitle)
            .navigationSubtitle(navigationSubtitle)
            .toolbar { toolbarContent }
        }
        .searchable(text: $model.searchQuery, prompt: "Search folders on every drive")
        .onChange(of: model.searchQuery) { _, _ in model.rerunSearch() }
        // The inspector only has content for a selected drive. Switching to
        // Backup Check (or search) would leave it open on an empty "no drive
        // selected" pane, so close it whenever a drive isn't what's showing.
        .onChange(of: model.selection) { _, _ in
            if model.selectedDrive == nil { showInspector = false }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - Detail content

    @ViewBuilder
    private var detail: some View {
        if model.isSearching {
            SearchResultsView(model: model)
        } else if model.selection == .backupCheck {
            BackupCheckView(model: model)
        } else if let drive = model.selectedDrive {
            DriveContentView(
                model: model, drive: drive,
                mode: mode, sort: sort, ascending: ascending
            )
        } else if model.drives.isEmpty {
            ContentUnavailableView(
                "No drives catalogued",
                systemImage: "externaldrive",
                description: Text("Plug in an external drive and DriveAtlas will scan it automatically.")
            )
        } else {
            ContentUnavailableView("Select a drive", systemImage: "sidebar.left")
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        // A drive is guaranteed selected — the panel only shows when it is — so
        // no empty-state branch is needed.
        if let drive = model.selectedDrive {
            DriveInspector(model: model, drive: drive)
        }
    }

    // MARK: - Window chrome

    private var navigationTitle: String {
        if model.isSearching { return "Search" }
        if model.selection == .backupCheck { return "Backup Check" }
        return model.selectedDrive?.name ?? "DriveAtlas"
    }

    /// Every state supplies one. A subtitle appearing and disappearing changes the
    /// titlebar's height, which moves every pane in the window.
    private var navigationSubtitle: String {
        if model.isSearching {
            return "\(model.searchResults.count) matches"
        }
        if model.selection == .backupCheck {
            guard let analysis = model.copyAnalysis else {
                return model.isAnalysing ? "Comparing…" : "Across \(model.drives.count) drives"
            }
            return "\(analysis.atRisk.count) with one copy · \(analysis.duplicated.count) duplicated"
        }
        guard let drive = model.selectedDrive else { return " " }

        var parts: [String] = [drive.kindLabel]
        if let age = drive.ageDescription { parts.append(age) }
        if let free = drive.freeBytes { parts.append("\(formatBytes(free)) free") }
        if let scanned = drive.lastScannedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append("scanned \(formatter.localizedString(for: scanned, relativeTo: Date()))")
        } else {
            parts.append("never scanned")
        }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The item set is kept structurally stable: buttons disable rather than
        // vanish, so the toolbar doesn't reflow between selections.
        ToolbarItem(placement: .automatic) {
            Picker("View", selection: $mode) {
                ForEach(TreeViewMode.allCases, id: \.self) { m in
                    Label(m.label, systemImage: m.symbol)
                        .help(m.help)
                        .tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .tint(AppColor.accent)   // selection control keeps the app accent
            // Disabled, NOT hidden. An earlier version set opacity to 0 here,
            // which left the toolbar with nothing visible on Backup Check —
            // AppKit then collapsed the toolbar row entirely, shortening the
            // titlebar and shifting every pane in the window upward.
            .disabled(!showsDriveControls)
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(FolderSort.allCases, id: \.self) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Picker("Order", selection: $ascending) {
                    Label(ascendingLabel, systemImage: "arrow.up").tag(true)
                    Label(descendingLabel, systemImage: "arrow.down").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sorted by \(sort.label.lowercased()), \(ascending ? "ascending" : "descending")")
            // Sorting only applies to the list view. Again: disabled, not hidden.
            .disabled(!(showsDriveControls && mode == .list))
        }

        ToolbarItem(placement: .automatic) {
            // On-demand rescan of the selected drive — the "I just deleted
            // duplicates and want fresh numbers" button. Disabled while that
            // drive is already scanning; complains helpfully if it's unplugged.
            Button {
                if let drive = model.selectedDrive { model.rescan(drive) }
            } label: {
                Label("Rescan", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(
                !showsDriveControls
                    || model.selectedDrive.map { model.scanStatus(for: $0) != nil } ?? true
            )
            .help("Rescan this drive now — it must be connected")
        }

        ToolbarItem(placement: .primaryAction) {
            // No Refresh button for Backup Check: the analysis recomputes itself
            // when scans finish, when a drive is forgotten, and on first visit —
            // and a second circular-arrow button next to Rescan read as a riddle.
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showInspector.toggle() }
            } label: {
                Label("Drive Info", systemImage: "info.circle")
            }
            .disabled(model.selectedDrive == nil)
        }
    }

    private var showsDriveControls: Bool {
        !model.isSearching && model.selectedDrive != nil
    }

    /// Direction labels track the field — "A to Z" and "Smallest first" mean the
    /// same direction but only one of them reads correctly for a given sort.
    private var ascendingLabel: String {
        switch sort {
        case .name: "A to Z"
        case .size: "Smallest first"
        case .files: "Fewest first"
        case .created, .modified: "Oldest first"
        }
    }

    private var descendingLabel: String {
        switch sort {
        case .name: "Z to A"
        case .size: "Largest first"
        case .files: "Most first"
        case .created, .modified: "Newest first"
        }
    }
}

// MARK: - Sidebar

struct DriveSidebar: View {
    @Bindable var model: AppModel
    @State private var driveToForget: Drive?

    var body: some View {
        // No `selection:` binding on the List, deliberately.
        //
        // With one, macOS paints its own filled capsule for the selected row —
        // and `listRowBackground` draws *behind* that, so a custom treatment
        // just adds a bar underneath the system fill rather than replacing it.
        // Rows are plain buttons that set the selection themselves, which
        // leaves this view in sole control of what "selected" looks like.
        //
        // Cost: the sidebar loses List's built-in arrow-key navigation. The
        // quick-search panel (⌃⌥Space) is the keyboard path through drives, and
        // it implements ↑↓ itself.
        List {
            Section("Overview") {
                SidebarItem(
                    isSelected: model.selection == .backupCheck,
                    action: { model.selection = .backupCheck }
                ) {
                    Label("Backup Check", systemImage: "checkmark.shield")
                }
            }

            Section("Drives") {
                ForEach(model.drives) { drive in
                    SidebarItem(
                        isSelected: model.selection == .drive(drive.id ?? -1),
                        action: { model.selection = .drive(drive.id ?? -1) }
                    ) {
                        DriveRow(drive: drive, status: model.scanStatus(for: drive))
                    }
                    .contextMenu {
                        Button("Rescan Now") {
                            model.rescan(drive)
                        }
                        .disabled(model.scanStatus(for: drive) != nil)

                        Divider()

                        // Ellipsis: this asks before doing anything.
                        Button("Forget \(drive.name)…", role: .destructive) {
                            driveToForget = drive
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Forget \(driveToForget?.name ?? "this drive")?",
            isPresented: Binding(
                get: { driveToForget != nil },
                set: { if !$0 { driveToForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget \(driveToForget?.name ?? "")", role: .destructive) {
                if let drive = driveToForget { model.forget(drive) }
                driveToForget = nil
            }
            Button("Cancel", role: .cancel) { driveToForget = nil }
        } message: {
            Text("This deletes everything catalogued from it — the drive itself is untouched. Plugging it back in catalogues it again from scratch, but manual settings like the purchase date are gone.")
        }
    }
}

struct DriveRow: View {
    let drive: Drive
    let status: AppModel.ScanStatus?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                // Connected drives are the ones seen in the last minute or so.
                .foregroundStyle(isConnected ? AppColor.accent : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(drive.name).lineLimit(1)

                if let status {
                    // A scan is running — say so, because the tree below is
                    // mid-refresh and may still show stale contents.
                    Text("Scanning… \(status.foldersScanned) folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if drive.needsRescan {
                    // The live watcher saw a change since the last scan — the
                    // catalog for this drive is known-stale. Rescan via the
                    // toolbar button or right-click → Rescan Now.
                    Label("Changed — rescan to update", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(AppColor.warning)
                        .help("Its contents changed since the last scan. Rescan to update the catalog.")
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: drive.kindSymbol)
                        Text(drive.kindLabel)
                        if let total = drive.totalBytes {
                            Text("· \(formatBytes(total))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let fraction = drive.usedFraction, let free = drive.freeBytes {
                        CapacityBar(fraction: fraction, nearlyFull: drive.isNearlyFull)
                        Text("\(formatBytes(free)) free")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(drive.isNearlyFull ? AppColor.warning : Color.secondary)
                    }
                }
            }

            Spacer()

            if drive.needsRescan && status == nil {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(AppColor.warning)
                    .help("Contents changed since last scan — rescan to update.")
            } else if drive.showsAgeWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("This SSD is 5+ years old — worth verifying your backups.")
            }
        }
        .padding(.vertical, 2)
    }

    private var isConnected: Bool {
        Date().timeIntervalSince(drive.lastSeenAt) < 60
    }
}

/// A sidebar row that draws its own selection via `SelectionBackground` — the
/// same treatment as the quick-search panel.
///
/// The system's filled capsule painted the whole row in the selection colour,
/// which reads far heavier than "this is the current item" needs to, and forced
/// white label text onto a saturated fill.
struct SidebarItem<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Same component the quick-search panel uses, so "selected" looks
        // identical in both places.
        .listRowBackground(
            SelectionBackground(isSelected: isSelected, isHovered: isHovered)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Drive detail

enum TreeViewMode: String, CaseIterable {
    case list, graph, treemap

    var label: String {
        switch self {
        case .list: "List"
        case .graph: "Map"
        case .treemap: "Sizes"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet.indent"
        case .graph: "point.topleft.down.to.point.bottomright.curvepath"
        case .treemap: "square.grid.2x2"
        }
    }

    var help: String {
        switch self {
        case .list: "Indented list \u{2014} best for folders with many children"
        case .graph: "Node map \u{2014} best for seeing the shape of a deep tree"
        case .treemap: "Size map \u{2014} area is disk usage, colour is file type"
        }
    }
}

/// A drive's contents. Pure content: no title, toolbar or inspector of its own —
/// `ContentView` owns all of those so the window's structure stays constant as
/// the selection changes.
struct DriveContentView: View {
    @Bindable var model: AppModel
    let drive: Drive
    let mode: TreeViewMode
    let sort: FolderSort
    let ascending: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let status = model.scanStatus(for: drive) {
                ScanningBanner(driveName: drive.name, foldersScanned: status.foldersScanned)
            }
            tree
        }
    }

    @ViewBuilder
    private var tree: some View {
        switch mode {
        case .list:
            FolderTreeView(drive: drive, store: model.store, sort: sort, ascending: ascending)
        case .graph:
            GraphTreeView(drive: drive, store: model.store)
        case .treemap:
            TreemapView(drive: drive, store: model.store)
        }
    }
}

/// Shown across the top of a drive's detail while it's being scanned. Advisory,
/// not a warning: the scan is read-only and rolls back cleanly if the drive is
/// pulled, so the honest message is "keep it connected so the update finishes",
/// never "don't remove or you'll lose data".
struct ScanningBanner: View {
    let driveName: String
    let foldersScanned: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scanning \(driveName) — keep it connected so this finishes")
                .font(.callout)
            Spacer(minLength: 8)
            Text("\(foldersScanned) folders")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.accent.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .help("DriveAtlas only reads the drive. Unplugging now won't harm it — the scan just rolls back and you keep the previous catalog.")
    }
}

/// Where the user corrects what the system couldn't detect.
struct DriveInspector: View {
    @Bindable var model: AppModel
    let drive: Drive

    var body: some View {
        Form {
            Section("Hardware") {
                LabeledContent("Model", value: drive.mediaName ?? "Unknown")
                LabeledContent("Connection", value: drive.busProtocol ?? "Unknown")
                LabeledContent("Capacity", value: drive.totalBytes.map(formatBytes) ?? "Unknown")
            }

            Section {
                Picker("Drive type", selection: typeBinding) {
                    Text("Auto-detect").tag(nil as Bool?)
                    Text("SSD").tag(true as Bool?)
                    Text("HDD").tag(false as Bool?)
                }
                if drive.isSolidStateDetected == nil {
                    // Explain rather than silently showing "Unknown" — this is the
                    // expected outcome for most USB enclosures, not a malfunction.
                    Text("macOS can't detect the type of most USB drives. Set it here if you know.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Type")
            }

            Section {
                if drive.purchasedOn == nil {
                    // Deliberately no pre-filled date. A DatePicker defaulting to
                    // today would invite an accidental "bought today" on a drive
                    // that's years old.
                    HStack {
                        Text("Purchased")
                        Spacer()
                        Text("Not set")
                            .foregroundStyle(.secondary)
                        Button("Set…") { model.setPurchaseDate(Date(), for: drive) }
                    }
                } else {
                    DatePicker(
                        "Purchased",
                        selection: purchaseBinding,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    Button("Clear date") { model.setPurchaseDate(nil, for: drive) }
                        .buttonStyle(.link)
                }

                LabeledContent("Age") {
                    Text(drive.ageDescription ?? "Unknown")
                        .foregroundStyle(drive.ageDescription == nil ? .secondary : .primary)
                }

                switch drive.ageBasis {
                case .purchased:
                    EmptyView()
                case .formatted:
                    Text("Based on when the volume was formatted, which resets every time you reformat — so this is a lower bound, not the drive's real age. Set the purchase date for something accurate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .unknown:
                    Text("macOS can't read SMART wear data over USB, and nothing else on the drive records when you bought it. Set the purchase date if you know it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if drive.needsAgeInfo {
                    Label(
                        "This is an SSD. Without a purchase date the wear warning can't work.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Age")
            }

            Section {
                LabeledContent(
                    "First catalogued",
                    value: drive.firstSeenAt.formatted(date: .abbreviated, time: .omitted)
                )
                LabeledContent(
                    "Last connected",
                    value: drive.lastSeenAt.formatted(date: .abbreviated, time: .shortened)
                )
                if let scanned = drive.lastScannedAt {
                    LabeledContent(
                        "Last scanned",
                        value: scanned.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            } header: {
                Text("Catalog")
            } footer: {
                // Naming this explicitly, because "first seen" sitting near an age
                // reads like a claim about the hardware. It's only when this app
                // first met the drive.
                Text("When DriveMapper first saw this drive — unrelated to how old the drive is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var typeBinding: Binding<Bool?> {
        Binding(
            get: { drive.isSolidStateOverride ?? drive.isSolidStateDetected },
            set: { model.setSolidStateOverride($0, for: drive) }
        )
    }

    private var purchaseBinding: Binding<Date> {
        Binding(
            get: { drive.purchasedOn ?? Date() },
            set: { model.setPurchaseDate($0, for: drive) }
        )
    }
}

// MARK: - Search

struct SearchResultsView: View {
    @Bindable var model: AppModel

    var body: some View {
        results
    }

    @ViewBuilder
    private var results: some View {
        if model.searchResults.isEmpty {
            ContentUnavailableView.search(text: model.searchQuery)
        } else {
            List(model.searchResults) { hit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: hit.folder.isLeafBundle ? "shippingbox" : "folder")
                                .foregroundStyle(AppColor.accent)
                            Text(hit.folder.name).fontWeight(.medium)
                            Spacer()
                            Text(formatBytes(hit.folder.totalBytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            // The drive name is the answer to the question the app
                            // exists to answer, so it leads.
                            Label(hit.driveName, systemImage: "externaldrive")
                                .font(.caption)
                                .foregroundStyle(AppColor.accent)
                            Text(hit.folder.path.isEmpty ? "/" : hit.folder.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                }
                .padding(.vertical, 3)
            }
        }
    }
}
