import SwiftUI
import DriveMapperCore

/// Cross-drive view: what has no second copy, and what has too many.
struct BackupCheckView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .atRisk

    enum Tab: String, CaseIterable {
        case atRisk, duplicated

        var label: String {
            switch self {
            case .atRisk: "Only one copy"
            case .duplicated: "On several drives"
            }
        }
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
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                    // No separator under a control — the line rendered flush
                    // against the buttons and read as part of them. Separators
                    // stay on the result rows, where they divide actual content.
                    .listRowSeparator(.hidden)
                }

                Section {
                    if groups(in: analysis).isEmpty {
                        emptyState
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
        tab == .atRisk ? analysis.atRisk : analysis.duplicated
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
                    tint: analysis.atRisk.isEmpty ? .secondary : .orange
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
            // tooltip. Nothing here inspects file contents.
            Label(
                "Matched on folder name and size — nothing reads file contents. Treat a match as worth checking, not a verified backup.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
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
                    .foregroundStyle(showsReclaim ? Color.secondary : .orange)
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
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(formatBytes(group.reclaimableBytes)) reclaimable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Where each copy actually lives — without this the row says a folder
            // is duplicated but not where to go looking.
            ForEach(group.locations) { location in
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Text(location.driveName)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
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
                    .fill(nearlyFull ? Color.orange : Color.accentColor)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        .padding(.top, 1)
    }
}
