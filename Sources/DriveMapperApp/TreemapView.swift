import SwiftUI
import AppKit
import DriveMapperCore

/// Treemap: nested rectangles where area is disk usage.
///
/// The node-link map assumes depth; a drive whose folders are mostly at the top
/// level degenerates into one very long row there. A treemap has the opposite
/// failure mode — it handles hundreds of siblings comfortably and struggles with
/// deep chains — so the two views complement each other.
///
/// Colour encodes the dominant file type. Only four hues are used, per the
/// validated categorical palette: a treemap is an all-pairs case (any rectangle
/// can end up beside any other), and beyond four slots the palette can't hold
/// colourblind separation. Everything past the drive's top four types folds into
/// a neutral "Other" rather than inventing a fifth hue.
struct TreemapView: View {
    let drive: Drive
    let store: Store

    /// Drill-down stack; last element is what's currently displayed.
    @State private var path: [Folder] = []
    @State private var tiles: [Tile] = []
    @State private var palette: [String: Int] = [:]   // extension -> colour slot
    @State private var legend: [(ext: String, slot: Int)] = []
    @State private var hidden = 0
    @State private var loadFailed = false
    @State private var hoveredId: Int64?

    /// Below this a tile can't hold a label or be reliably clicked, so it's
    /// dropped and reported in the footer instead of rendered as a sliver.
    private let minTileSide: CGFloat = 24

    struct Tile: Identifiable {
        let id: Int64
        let folder: Folder
        var rect: CGRect
        let ext: String?
        let slot: Int      // -1 = "Other"
        let canDrill: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            map
            Divider()
            legendBar
        }
        .task(id: drive.id) { reset() }
    }

    // MARK: - Map

    private var map: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)

                if loadFailed {
                    ContentUnavailableView(
                        "Not scanned yet",
                        systemImage: "externaldrive.badge.questionmark",
                        description: Text("Plug in \(drive.name) and it'll be catalogued automatically.")
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                } else if tiles.isEmpty {
                    ContentUnavailableView(
                        "Nothing to show",
                        systemImage: "square.dashed",
                        description: Text("This folder has no measurable contents.")
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ForEach(tiles) { tile in
                        TileView(
                            tile: tile,
                            store: store,
                            isHovered: hoveredId == tile.id,
                            onHover: { hoveredId = $0 ? tile.id : nil },
                            onTap: { drill(into: tile) }
                        )
                        .frame(width: tile.rect.width, height: tile.rect.height)
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                    }
                }
            }
            // `initial: true` matters more than it looks. The tiles are cached in
            // state against a snapshot of the geometry, so if the view is ever
            // laid out at a near-zero size and no *further* size change arrives,
            // it stays stuck at that size — which is what happened coming back
            // from the search results: the map returned as a small square in the
            // corner. Firing on appear with the real size makes that
            // unrepresentable, and recomputing on folder change removes the need
            // to call the layout by hand from the drill and breadcrumb actions.
            .onChange(of: geo.size, initial: true) { _, newSize in
                lastSize = newSize
                recompute()
            }
            .onChange(of: currentFolderId, initial: true) { _, _ in recompute() }
        }
    }

    // MARK: - Chrome

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Button {
                path = Array(path.prefix(1))
            } label: {
                Label(drive.name, systemImage: "externaldrive")
            }
            .buttonStyle(.plain)
            .foregroundStyle(path.count <= 1 ? Color.primary : AppColor.accent)

            ForEach(Array(path.dropFirst().enumerated()), id: \.element.id) { index, folder in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    path = Array(path.prefix(index + 2))
                } label: {
                    Text(folder.name)
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == path.count - 2 ? Color.primary : AppColor.accent)
            }

            Spacer()

            if path.count > 1 {
                Button {
                    path.removeLast()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var legendBar: some View {
        HStack(spacing: 14) {
            ExtensionLegendView(legend: legend)

            Spacer()

            if hidden > 0 {
                Text("\(hidden) too small to show")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Folders below a few pixels are omitted — use the list view to see them all.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Data

    private func reset() {
        loadFailed = false
        path = []
        guard let driveId = drive.id,
              let root = try? store.rootFolder(driveId: driveId)
        else {
            loadFailed = true
            tiles = []
            return
        }

        // Colour slots are assigned once per drive, from the drive's biggest file
        // types — so a folder's colour means the same thing wherever you drill.
        let top = (try? store.topExtensions(driveId: driveId, limit: TreemapPalette.slotCount)) ?? []
        palette = Dictionary(uniqueKeysWithValues: top.enumerated().map { ($0.element.ext, $0.offset) })
        legend = top.enumerated().map { (ext: $0.element.ext, slot: $0.offset) }

        path = [root]
    }

    private func drill(into tile: Tile) {
        guard tile.canDrill else { return }
        path.append(tile.folder)
        // No explicit relayout — the folder-change observer handles it.
    }

    @State private var lastSize: CGSize = .zero

    private var currentFolderId: Int64? { path.last?.id }

    private func recompute() {
        let size = lastSize
        // Too small to be a real layout pass. Leave the existing tiles alone and
        // wait for a usable size rather than baking in a degenerate one.
        guard size.width > 40, size.height > 40 else { return }

        guard let currentId = currentFolderId else {
            tiles = []
            return
        }

        let children = ((try? store.children(of: currentId)) ?? [])
            .filter { $0.totalBytes > 0 }
        guard !children.isEmpty else {
            tiles = []
            hidden = 0
            return
        }

        let dominant = (try? store.dominantExtensions(
            for: children.compactMap(\.id)
        )) ?? [:]

        let placed = squarify(
            children.map { (id: $0.id ?? 0, value: Double($0.totalBytes)) },
            in: CGRect(origin: .zero, size: size)
        )
        let rectsById = Dictionary(uniqueKeysWithValues: placed)
        let byId = Dictionary(uniqueKeysWithValues: children.compactMap { f in f.id.map { ($0, f) } })

        var result: [Tile] = []
        var dropped = 0
        for (id, rect) in rectsById {
            guard let folder = byId[id] else { continue }
            // 2px gap between fills, per the mark spec — it also doubles as the
            // secondary encoding the palette's CVD band requires.
            let inset = rect.insetBy(dx: 1, dy: 1)
            guard inset.width >= minTileSide, inset.height >= minTileSide else {
                dropped += 1
                continue
            }
            let ext = dominant[id]
            result.append(Tile(
                id: id,
                folder: folder,
                rect: inset,
                ext: ext,
                slot: ext.flatMap { palette[$0] } ?? -1,
                canDrill: !folder.isLeafBundle && ((try? store.hasChildren(id)) ?? false)
            ))
        }

        tiles = result.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        hidden = dropped
    }

    // MARK: - Squarified layout

    /// Squarified treemap (Bruls, Huizing & van Wijk).
    ///
    /// Greedily fills rows along the rectangle's shorter side, extending a row
    /// only while doing so improves the worst aspect ratio in it. Produces tiles
    /// close to square, which are far easier to compare by area than the long
    /// slivers a naive slice-and-dice gives.
    private func squarify(_ items: [(id: Int64, value: Double)], in bounds: CGRect) -> [(Int64, CGRect)] {
        let total = items.reduce(0.0) { $0 + $1.value }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }

        let scale = Double(bounds.width) * Double(bounds.height) / total
        var remaining = items
            .map { (id: $0.id, area: $0.value * scale) }
            .sorted { $0.area > $1.area }

        var result: [(Int64, CGRect)] = []
        var rect = bounds

        while !remaining.isEmpty {
            let side = Double(min(rect.width, rect.height))
            guard side > 0 else { break }

            var row: [(id: Int64, area: Double)] = []
            var rowArea = 0.0
            while let next = remaining.first {
                let candidateArea = rowArea + next.area
                if row.isEmpty ||
                    worstAspect(row + [next], candidateArea, side) <= worstAspect(row, rowArea, side) {
                    row.append(next)
                    rowArea = candidateArea
                    remaining.removeFirst()
                } else {
                    break
                }
            }
            guard !row.isEmpty, rowArea > 0 else { break }

            let thickness = CGFloat(rowArea / side)
            if rect.width <= rect.height {
                var x = rect.minX
                for item in row {
                    let w = CGFloat(item.area / rowArea) * rect.width
                    result.append((item.id, CGRect(x: x, y: rect.minY, width: w, height: thickness)))
                    x += w
                }
                rect = CGRect(
                    x: rect.minX, y: rect.minY + thickness,
                    width: rect.width, height: max(0, rect.height - thickness)
                )
            } else {
                var y = rect.minY
                for item in row {
                    let h = CGFloat(item.area / rowArea) * rect.height
                    result.append((item.id, CGRect(x: rect.minX, y: y, width: thickness, height: h)))
                    y += h
                }
                rect = CGRect(
                    x: rect.minX + thickness, y: rect.minY,
                    width: max(0, rect.width - thickness), height: rect.height
                )
            }
        }
        return result
    }

    /// Worst aspect ratio in a row — the quantity the algorithm minimises.
    private func worstAspect(_ row: [(id: Int64, area: Double)], _ rowArea: Double, _ side: Double) -> Double {
        guard !row.isEmpty, rowArea > 0 else { return .infinity }
        let maxArea = row.map(\.area).max() ?? 0
        let minArea = row.map(\.area).min() ?? 0
        guard minArea > 0 else { return .infinity }
        let side2 = side * side
        let area2 = rowArea * rowArea
        return max(side2 * maxArea / area2, area2 / (side2 * minArea))
    }
}

// MARK: - Tile

struct TileView: View {
    let tile: TreemapView.Tile
    let store: Store
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    /// Drives the popover directly, rather than a separate `isPresented` flag.
    ///
    /// With `isPresented` the node was created and the flag set in the same update
    /// cycle, and SwiftUI could present the popover before the node landed — the
    /// content closure then saw `nil`, rendered nothing, and the popover collapsed
    /// to a tiny empty bubble. Hovering away and back worked only because the node
    /// was populated by then. `popover(item:)` presents and supplies the value
    /// atomically, so the content can never be empty.
    @State private var popoverNode: TreeNode?

    var body: some View {
        Button(action: onTap) {
            content
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            onHover(hovering)
            if hovering {
                let node = TreeNode(folder: tile.folder, hasChildren: tile.canDrill)
                node.loadExtensionsIfNeeded(store: store)
                popoverNode = node
            } else {
                popoverNode = nil
            }
        }
        .popover(item: $popoverNode, arrowEdge: .top) { node in
            ExtensionBreakdownView(node: node)
        }
    }

    private var content: some View {
        let fill = TreemapPalette.color(slot: tile.slot)
        // Ink is picked for contrast against the fill, not from the palette —
        // labels are required relief for the light-mode contrast warning, so they
        // have to stay legible on every hue.
        let ink = TreemapPalette.ink(onSlot: tile.slot)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isHovered ? ink.opacity(0.9) : .clear, lineWidth: 2)
                )

            if tile.rect.width >= 54 && tile.rect.height >= 30 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.folder.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(tile.rect.height >= 46 ? 2 : 1)
                        .truncationMode(.middle)
                    if tile.rect.height >= 42 {
                        Text(formatBytes(tile.folder.totalBytes))
                            .font(.caption2.monospacedDigit())
                            .opacity(0.85)
                    }
                    if tile.rect.height >= 66, let ext = tile.ext, !ext.isEmpty {
                        Text(".\(ext)")
                            .font(.caption2.monospaced())
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(ink)
                .padding(5)
            }

            if tile.canDrill && tile.rect.width >= 54 && tile.rect.height >= 30 {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.down.right.and.arrow.up.left.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(ink.opacity(0.55))
                            .padding(4)
                    }
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .help("\(tile.folder.name) — \(formatBytes(tile.folder.totalBytes))")
    }
}

// MARK: - Legend

/// Colour swatches for the drive's top file types plus "Other".
///
/// Shared between the treemap and the node map so the same colour reads the same
/// everywhere. A legend is always present wherever the palette is used —
/// identity must never rest on colour alone.
struct ExtensionLegendView: View {
    let legend: [(ext: String, slot: Int)]
    /// The node map draws the drive root in its reserved colour; the treemap
    /// never draws the root as a tile, so it leaves this off.
    var includesDrive = false

    var body: some View {
        HStack(spacing: 14) {
            if includesDrive {
                swatch(TreemapPalette.driveRoot, "Drive")
            }
            ForEach(legend, id: \.ext) { entry in
                swatch(
                    TreemapPalette.color(slot: entry.slot),
                    entry.ext.isEmpty ? "no extension" : ".\(entry.ext)"
                )
            }
            if !legend.isEmpty {
                swatch(TreemapPalette.other, "Other")
            }
        }
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 11, height: 11)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Palette

/// Validated categorical palette, four slots plus a neutral "Other".
///
/// Values come from the reference palette and were checked with the six-check
/// validator under `--pairs all` (a treemap is an all-pairs case) in both light
/// and dark modes. Don't add a fifth hue: the palette stops clearing colourblind
/// separation past four slots, which is why everything else folds to "Other".
enum TreemapPalette {
    /// Three file-type slots, not four. The amber that held slot 3 now belongs
    /// to the drive root (user request), and no replacement hue exists: the
    /// validator rejects every candidate as a categorical slot next to these
    /// three — violet≈blue ΔE 1.9, red≈magenta 7.8, aqua≈green, orange≈green
    /// 2.7, and the whole teal region either leaves the dark lightness band or
    /// collapses to ΔE ~4.5 against magenta for deutan viewers (all measured).
    /// So the fourth-biggest file type folds into "Other" rather than wearing a
    /// colour someone can't distinguish.
    static let slotCount = 3

    static func color(slot: Int) -> Color {
        switch slot {
        case 0: dynamic(light: 0x2a78d6, dark: 0x3987e5)   // blue
        case 1: dynamic(light: 0x008300, dark: 0x008300)   // green
        case 2: dynamic(light: 0xe87ba4, dark: 0xd55181)   // magenta
        default: other
        }
    }

    static let other = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.38, alpha: 1)
            : NSColor(white: 0.72, alpha: 1)
    })

    /// Reserved for the drive root — the amber that used to be file-type slot 3.
    /// Moving it here is what cost the palette its fourth slot (see `slotCount`);
    /// the root itself can wear it safely because the root is never identified by
    /// colour alone — unique icon, position, and legend entry.
    static let driveRoot = dynamic(light: 0xeda100, dark: 0xc98500)

    /// The amber's original ink: bright in light mode (dark ink), deeper in dark
    /// mode (white ink).
    static let driveRootInk = dynamic(light: 0x1a1a19, dark: 0xffffff)

    /// Black or white, whichever reads on the given fill.
    static func ink(onSlot slot: Int) -> Color {
        // The light-mode magenta and yellow are bright enough to need dark ink;
        // blue and green need light ink. Slot -1 (grey) takes dark in light mode.
        switch slot {
        case 0, 1: return .white
        case 2, 3: return dynamic(light: 0x1a1a19, dark: 0xffffff)
        default: return dynamic(light: 0x1a1a19, dark: 0xffffff)
        }
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(rgb: dark)
                : NSColor(rgb: light)
        })
    }
}

extension NSColor {
    convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
