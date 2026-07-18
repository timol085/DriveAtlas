import SwiftUI
import Observation
import DriveMapperCore

/// One node in the displayed tree.
///
/// Children load on first expand rather than up front — a large drive has
/// hundreds of thousands of folders and materialising them all would freeze the
/// window. Each expansion is a single indexed query on `folder.parentId`.
@Observable
@MainActor
final class TreeNode: Identifiable {
    let folder: Folder
    var children: [TreeNode]?
    let hasChildren: Bool
    var isExpanded = false
    /// Rollup stats — this folder and everything under it.
    var extensions: [FolderExtension]?
    /// Files sitting directly in this folder, with no subfolder of their own.
    var ownExtensions: [FolderExtension]?
    /// Biggest file type in this subtree, for colour mapping. Populated in a
    /// single batched query when the parent loads its children — never per-node
    /// during layout.
    var dominantExt: String?

    nonisolated var id: Int64 { folder.id ?? 0 }

    init(folder: Folder, hasChildren: Bool) {
        self.folder = folder
        self.hasChildren = hasChildren
    }

    func loadChildrenIfNeeded(store: Store) {
        guard children == nil, let id = folder.id else { return }
        let loaded = ((try? store.children(of: id)) ?? []).map { child in
            TreeNode(
                folder: child,
                // A bundle is a leaf by construction — never draw a disclosure
                // triangle we'd have nothing to put under.
                hasChildren: child.isLeafBundle
                    ? false
                    : ((try? store.hasChildren(child.id ?? 0)) ?? false)
            )
        }
        // One batched query for the whole sibling set, keyed on the PK.
        if let dominant = try? store.dominantExtensions(for: loaded.compactMap(\.folder.id)) {
            for child in loaded {
                child.dominantExt = child.folder.id.flatMap { dominant[$0] }
            }
        }
        children = loaded
    }

    /// Loaded on hover, not with the row — these are extra queries per folder and
    /// only a handful of folders are ever hovered.
    func loadExtensionsIfNeeded(store: Store) {
        guard extensions == nil, let id = folder.id else { return }
        extensions = (try? store.extensions(of: id, rollup: true)) ?? []
        ownExtensions = (try? store.extensions(of: id, rollup: false)) ?? []
    }
}

/// One line in the flattened tree.
struct VisibleRow: Identifiable {
    let node: TreeNode
    let depth: Int
    var id: Int64 { node.id }
}

enum FolderSort: String, CaseIterable {
    case name, size, files, created, modified

    var label: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .files: "File count"
        case .created: "Date created"
        case .modified: "Date modified"
        }
    }

    var symbol: String {
        switch self {
        case .name: "textformat"
        case .size: "internaldrive"
        case .files: "doc.on.doc"
        case .created: "calendar.badge.plus"
        case .modified: "calendar"
        }
    }

    var isDate: Bool { self == .created || self == .modified }

    /// Orders two folders, `ascending` applied by the caller.
    ///
    /// Missing dates always sort last regardless of direction — a folder whose
    /// creation date we don't have is unknown, not oldest, and floating those to
    /// the top when sorting ascending would be actively misleading.
    func compare(_ a: Folder, _ b: Folder, ascending: Bool) -> Bool {
        func direct(_ result: Bool) -> Bool { ascending ? result : !result }

        switch self {
        case .name:
            return direct(a.name.localizedStandardCompare(b.name) == .orderedAscending)
        case .size:
            if a.totalBytes == b.totalBytes {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return direct(a.totalBytes < b.totalBytes)
        case .files:
            if a.totalFileCount == b.totalFileCount {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return direct(a.totalFileCount < b.totalFileCount)
        case .created, .modified:
            let lhs = self == .created ? a.createdAt : a.mtime
            let rhs = self == .created ? b.createdAt : b.mtime
            switch (lhs, rhs) {
            case (nil, nil):
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case (nil, _): return false   // unknown sinks
            case (_, nil): return true
            case let (l?, r?):
                if l == r {
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                return direct(l < r)
            }
        }
    }
}

struct FolderTreeView: View {
    let drive: Drive
    let store: Store
    var sort: FolderSort = .name
    var ascending: Bool = true
    @State private var root: TreeNode?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let root {
                // Flat list of visible rows, not nested views.
                //
                // Rendering each subtree *inside* a List row meant every top-level
                // folder was one enormous row containing all its descendants, and
                // List's own row gesture handling swallowed clicks meant for the
                // rows within. Flattening makes every folder a real, separate row.
                List(visibleRows(root)) { row in
                    FolderRowView(node: row.node, store: store, depth: row.depth, sort: sort)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 8))
                }
                .listStyle(.inset)
            } else if loadFailed {
                ContentUnavailableView(
                    "Not scanned yet",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Plug in \(drive.name) and it'll be catalogued automatically.")
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: drive.id) { load() }
    }

    /// Walks the expanded portion of the tree into a flat, ordered row list.
    ///
    /// Reading `isExpanded` here is what registers the SwiftUI dependency, so
    /// toggling a node re-runs this and the list updates.
    private func visibleRows(_ root: TreeNode) -> [VisibleRow] {
        var rows: [VisibleRow] = []

        // Sorting happens at display time, not load time, so changing the order
        // doesn't require re-querying anything — and each level sorts
        // independently, which is what keeps the tree a tree.
        func ordered(_ nodes: [TreeNode]) -> [TreeNode] {
            nodes.sorted { sort.compare($0.folder, $1.folder, ascending: ascending) }
        }

        func walk(_ node: TreeNode, depth: Int) {
            rows.append(VisibleRow(node: node, depth: depth))
            guard node.isExpanded, let children = node.children else { return }
            for child in ordered(children) { walk(child, depth: depth + 1) }
        }
        // Skip the root itself — the drive name is already the window title.
        for child in ordered(root.children ?? []) { walk(child, depth: 0) }
        return rows
    }

    private func load() {
        loadFailed = false
        root = nil
        guard let driveId = drive.id,
              let rootFolder = try? store.rootFolder(driveId: driveId)
        else {
            loadFailed = true
            return
        }
        let node = TreeNode(folder: rootFolder, hasChildren: true)
        node.loadChildrenIfNeeded(store: store)
        root = node
    }
}

/// A single row. Indentation is manual because the tree is flattened before it
/// reaches the List — see `FolderTreeView.visibleRows`.
struct FolderRowView: View {
    let node: TreeNode
    let store: Store
    let depth: Int
    var sort: FolderSort = .name

    @State private var isHovered = false
    @State private var showPopover = false

    var body: some View {
        // A Button, not `.onTapGesture`. On macOS a List consumes the first click
        // to take focus, so a tap gesture on a row needs two clicks — one to focus
        // the list, one to actually register. Buttons respond on the first click
        // regardless of focus.
        Button(action: toggle) {
            rowContent
        }
        .buttonStyle(.plain)
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

            // Plain image, not a Button: a nested button inside a List row competes
            // with the row's own tap handling, which is what made expanding take
            // several clicks. One tap target for the whole row is also just how
            // Finder behaves.
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .opacity(node.hasChildren ? 1 : 0)

            Image(systemName: node.folder.isLeafBundle ? "shippingbox" : "folder")
                .foregroundStyle(node.folder.isLeafBundle ? .orange : .accentColor)
                .font(.callout)

            Text(node.folder.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // Whatever you're sorting by is what gets shown — sorting by date is
            // no use if the dates aren't on screen to compare.
            if sort.isDate {
                Text(dateLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(dateValue == nil ? .tertiary : .secondary)
                    .help(dateValue == nil
                          ? "Recorded before dates were catalogued — rescan the drive to fill this in"
                          : dateLabel)
            } else if sort == .files {
                Text("\(node.folder.totalFileCount) files")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if node.folder.isLeafBundle && node.folder.totalBytes == 0 {
                // Deliberately unsized (node_modules and friends). Saying "Zero KB"
                // would be a lie; this says we chose not to look.
                Text("not indexed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(formatBytes(node.folder.totalBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        // contentShape after the frame so the full row width is clickable, not
        // just the text. The Button in `body` handles the click itself.
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                node.loadExtensionsIfNeeded(store: store)
                showPopover = true
            } else {
                showPopover = false
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            ExtensionBreakdownView(node: node)
        }
    }

    private var dateValue: Date? {
        sort == .created ? node.folder.createdAt : node.folder.mtime
    }

    private var dateLabel: String {
        guard let dateValue else { return "unknown" }
        return dateValue.formatted(date: .abbreviated, time: .omitted)
    }

    private func toggle() {
        guard node.hasChildren else { return }
        node.loadChildrenIfNeeded(store: store)
        withAnimation(.easeOut(duration: 0.15)) {
            node.isExpanded.toggle()
        }
    }
}

/// The hover content: what file types live in this branch.
struct ExtensionBreakdownView: View {
    let node: TreeNode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(node.folder.name)
                .font(.headline)
                .lineLimit(1)

            if node.folder.isLeafBundle && node.folder.totalBytes == 0 {
                Text("Recorded but not indexed — its contents aren't catalogued.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 220, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    Label(formatBytes(node.folder.totalBytes), systemImage: "internaldrive")
                    Label("\(node.folder.totalFileCount) files", systemImage: "doc")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let extensions = node.extensions, !extensions.isEmpty {
                    Divider()
                    // Rollup, so a top-level folder still says something useful
                    // instead of showing an empty list.
                    Text("Everything below here")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(extensions.prefix(8), id: \.ext) { ext in
                        extensionRow(
                            ext: ext.ext, count: ext.rollCount, bytes: ext.rollBytes
                        )
                    }

                    // Files sitting loose in this folder, as opposed to inside a
                    // subfolder. Only shown when they exist and the rollup isn't
                    // already just these — otherwise it's the same list twice.
                    if let own = node.ownExtensions, !own.isEmpty,
                       node.folder.ownFileCount < node.folder.totalFileCount {
                        Divider()
                        Text("Loose in this folder — \(node.folder.ownFileCount) file\(node.folder.ownFileCount == 1 ? "" : "s")")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(own.prefix(5), id: \.ext) { ext in
                            extensionRow(
                                ext: ext.ext, count: ext.ownCount, bytes: ext.ownBytes
                            )
                        }
                    }
                } else if node.extensions != nil {
                    Text("No files in this branch")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        // A floor on both axes: a popover with no intrinsic size collapses into a
        // small empty bubble rather than showing nothing, which reads as a glitch.
        .frame(minWidth: 240, minHeight: 64, alignment: .topLeading)
    }

    private func extensionRow(ext: String, count: Int, bytes: Int64) -> some View {
        HStack(spacing: 8) {
            Text(ext.isEmpty ? "no extension" : ".\(ext)")
                .font(.caption.monospaced())
                .frame(width: 90, alignment: .leading)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(formatBytes(bytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 66, alignment: .trailing)
        }
    }
}
