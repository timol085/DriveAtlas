import SwiftUI
import DriveMapperCore

/// Cross-drive view: what has no second copy, and what has too many.
struct BackupCheckView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .atRisk
    // Persisted so the choice sticks, like the folder-tree sort. The sort
    // *logic* lives in `CopyAnalysis.SortField` (Core, unit-tested); only the
    // label and icon are presentation, below.
    @AppStorage("backupSort") private var sortField: CopyAnalysis.SortField = .size
    @AppStorage("backupSortAscending") private var ascending = false

    enum Tab: String, CaseIterable {
        case atRisk, duplicated

        var label: String {
            switch self {
            case .atRisk: "Only one copy"
            case .duplicated: "On several drives"
            }
        }
    }

    private func sortLabel(_ field: CopyAnalysis.SortField) -> String {
        switch field {
        case .size: "Size"
        case .name: "Name"
        case .drive: "Drive"
        case .reclaimable: "Reclaimable space"
        case .copies: "Number of copies"
        }
    }

    private func sortSymbol(_ field: CopyAnalysis.SortField) -> String {
        switch field {
        case .size: "internaldrive"
        case .name: "textformat"
        case .drive: "externaldrive"
        case .reclaimable: "arrow.down.circle"
        case .copies: "doc.on.doc"
        }
    }

    private var sortOptions: [CopyAnalysis.SortField] {
        CopyAnalysis.SortField.fields(duplicated: tab == .duplicated)
    }

    /// The sort actually in effect — falls back to the tab's first option when
    /// the persisted field doesn't apply to the current tab (e.g. "Reclaimable"
    /// carried over to the single-copy tab).
    private var activeSort: CopyAnalysis.SortField {
        sortOptions.contains(sortField) ? sortField : (sortOptions.first ?? .size)
    }

    var body: some View {
        content
            // No title/subtitle/toolbar here — ContentView owns the window chrome
            // so it stays constant across selections.
            .task {
                if model.copyAnalysis == nil { model.runCopyAnalysis() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let analysis = model.copyAnalysis {
            // Everything lives INSIDE one bare List — summary, picker, rows.
            //
            // Hard-won constraint, established by bisection with DebugBridge
            // dumps: both `VStack { summary; List }` and
            // `List(...).safeAreaInset(edge: .top) { summary }` make the detail
            // column report a huge ideal height (1464pt in a 620pt window). The
            // NavigationSplitView then adopts that ideal and centres it, pushing
            // the entire window contents — sidebar included — ~400pt out of
            // frame, and the layout stays broken after switching away. A List
            // with nothing bolted onto it sizes to the space it's given, which
            // is why the drive views never misbehaved. Don't reintroduce either
            // pattern here.
            List {
                if !analysis.drivesNeedingRescan.isEmpty {
                    Section {
                        rescanBanner(analysis.drivesNeedingRescan)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                }

                Section {
                    summary(analysis)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                // The picker gets its own Section: rows within a section sit
                // flush against each other (measured 0pt between the picker and
                // the first group row), while a section boundary contributes the
                // list's natural 20pt gap.
                Section {
                    HStack(spacing: 8) {
                        Picker("", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .tint(AppColor.accent)

                        sortMenu
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                    // No separator under a control — the line rendered flush
                    // against the buttons and read as part of them. Separators
                    // stay on the result rows, where they divide actual content.
                    .listRowSeparator(.hidden)
                }

                Section {
                    if groups(in: analysis).isEmpty {
                        // Still a list row (the bare-List rule from the balloon
                        // bug), but dressed as a real empty state: full row
                        // width so it centres itself, enough height to breathe,
                        // and no separator line under a non-item.
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: 280)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(groups(in: analysis)) { group in
                            GroupRow(group: group, showsReclaim: tab == .duplicated)
                        }
                    }
                }
            }
            .listStyle(.inset)
        } else if model.isAnalysing {
            ProgressView("Comparing drives…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Backup Check",
                systemImage: "checkmark.shield",
                description: Text("Compares folders across all your drives to find what has no second copy.")
            )
        }
    }

    private func groups(in analysis: CopyAnalysis) -> [CopyAnalysis.Group] {
        let base = tab == .atRisk ? analysis.atRisk : analysis.duplicated
        // Sorting is applied here, at display time, so switching field or
        // direction is instant — it never re-runs the cross-drive comparison.
        return base.sorted(by: activeSort, ascending: ascending)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: sortFieldBinding) {
                ForEach(sortOptions, id: \.self) { option in
                    Label(sortLabel(option), systemImage: sortSymbol(option)).tag(option)
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
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sorted by \(sortLabel(activeSort).lowercased()), \(ascending ? "ascending" : "descending")")
    }

    /// Writes through `activeSort` so picking a field also normalises the
    /// direction to that field's natural default (biggest-first for size,
    /// A→Z for name) — the same courtesy the Finder does.
    private var sortFieldBinding: Binding<CopyAnalysis.SortField> {
        Binding(
            get: { activeSort },
            set: { newField in
                ascending = !newField.defaultsDescending
                sortField = newField
            }
        )
    }

    private var ascendingLabel: String {
        switch activeSort {
        case .name, .drive: "A to Z"
        case .size, .reclaimable: "Smallest first"
        case .copies: "Fewest first"
        }
    }

    private var descendingLabel: String {
        switch activeSort {
        case .name, .drive: "Z to A"
        case .size, .reclaimable: "Largest first"
        case .copies: "Most first"
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            tab == .atRisk ? "Everything has a second copy" : "No duplicates found",
            systemImage: tab == .atRisk ? "checkmark.circle" : "doc.on.doc",
            description: Text(
                tab == .atRisk
                    ? "Every folder above the size floor appears on at least two drives."
                    : "Nothing large enough appears on more than one drive."
            )
        )
    }

    // MARK: - Summary

    private func summary(_ analysis: CopyAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                stat(
                    value: formatBytes(analysis.atRiskBytes),
                    label: "with no second copy",
                    detail: "\(analysis.atRisk.count) folders",
                    tint: analysis.atRisk.isEmpty ? .secondary : AppColor.warning
                )
                stat(
                    value: formatBytes(analysis.reclaimableBytes),
                    label: "reclaimable",
                    detail: "\(analysis.duplicated.count) duplicated",
                    tint: .secondary
                )
                Spacer()
            }

            // The honest caveat, stated where it's read rather than buried in a
            // tooltip. Content matching compares file names + sizes, never file
            // bytes — and the camera case the caveat calls out is real.
            Label(
                "Folders are matched by the names and sizes of the files inside them — never file contents. That means a camera reusing a filename like 001.arw for a different photo can look identical here, so treat a match as worth checking, not a verified backup.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    /// Shown when drives were scanned before file fingerprints existed, so their
    /// content can't be compared yet. Framed as "results are incomplete", never
    /// as an all-clear.
    private func rescanBanner(_ drives: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("Rescan needed for accurate results")
                    .font(.callout.weight(.medium))
                Text("These drives were catalogued before content checking existed, so they're not being compared yet: \(drives.joined(separator: ", ")). Connect and rescan each one. Until then, an empty result here does not mean everything is backed up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.warning.opacity(0.10))
    }

    private func stat(value: String, label: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
    }

}

struct GroupRow: View {
    let group: CopyAnalysis.Group
    let showsReclaim: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: showsReclaim ? "doc.on.doc" : "exclamationmark.triangle")
                    .foregroundStyle(showsReclaim ? Color.secondary : AppColor.warning)
                Text(group.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(formatBytes(group.representativeBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if showsReclaim {
                HStack(spacing: 6) {
                    Text("\(group.driveCount) drives")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(formatBytes(group.reclaimableBytes)) reclaimable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let overlap = group.overlap {
                        Text("·").foregroundStyle(.tertiary)
                        // "identical" when the file sets match exactly, otherwise
                        // the honest weakest-link overlap so a partial backup
                        // (some newer files missing) reads as such.
                        Text(overlap >= 0.999 ? "identical files"
                                              : "\(Int((overlap * 100).rounded()))% same files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Where each copy actually lives — without this the row says a folder
            // is duplicated but not where to go looking.
            ForEach(group.locations) { location in
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive")
                        .font(.caption2)
                        .foregroundStyle(AppColor.accent)
                    Text(location.driveName)
                        .font(.caption)
                        .foregroundStyle(AppColor.accent)
                    Text(location.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Thin capacity meter for the sidebar.
struct CapacityBar: View {
    let fraction: Double
    let nearlyFull: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(nearlyFull ? AppColor.warning : AppColor.accent)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        .padding(.top, 1)
    }
}
