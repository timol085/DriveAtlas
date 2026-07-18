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
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(navigationTitle)
                .navigationSubtitle(navigationSubtitle)
                // Always present, so the column count never changes. Its contents
                // vary; its existence doesn't.
                .inspector(isPresented: $showInspector) {
                    inspectorContent
                        .inspectorColumnWidth(min: 260, ideal: 300)
                }
                .toolbar { toolbarContent }
        }
        .searchable(text: $model.searchQuery, prompt: "Search folders on every drive")
        .onChange(of: model.searchQuery) { _, _ in model.rerunSearch() }
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
        if let drive = model.selectedDrive {
            DriveInspector(model: model, drive: drive)
        } else {
            ContentUnavailableView(
                "No drive selected",
                systemImage: "externaldrive",
                description: Text("Pick a drive in the sidebar to see its details.")
            )
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

        ToolbarItem(placement: .primaryAction) {
            // One Button whose action and label vary, rather than two Buttons in
            // an if/else. Branching produces different view identities, so the
            // toolbar item is torn down and rebuilt on every selection change.
            Button {
                if model.selection == .backupCheck {
                    model.runCopyAnalysis()
                } else {
                    showInspector.toggle()
                }
            } label: {
                Label(
                    model.selection == .backupCheck ? "Refresh" : "Drive Info",
                    systemImage: model.selection == .backupCheck
                        ? "arrow.clockwise"
                        : "info.circle"
                )
            }
            .disabled(
                model.selection == .backupCheck
                    ? model.isAnalysing
                    : model.selectedDrive == nil
            )
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
        List(selection: $model.selection) {
            Section("Overview") {
                Label("Backup Check", systemImage: "checkmark.shield")
                    .tag(AppModel.Selection.backupCheck)
            }

            Section("Drives") {
                ForEach(model.drives) { drive in
                    DriveRow(drive: drive, status: model.scanStatus(for: drive))
                        .tag(AppModel.Selection.drive(drive.id ?? -1))
                        .contextMenu {
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
                .foregroundStyle(isConnected ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(drive.name).lineLimit(1)

                if let status {
                    // A scan is running — say so, because the tree below is
                    // mid-refresh and may still show stale contents.
                    Text("Scanning… \(status.foldersScanned) folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(drive.isNearlyFull ? Color.orange : Color.secondary)
                    }
                }
            }

            Spacer()

            if drive.showsAgeWarning {
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
                                .foregroundStyle(Color.accentColor)
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
                                .foregroundStyle(Color.accentColor)
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
