import SwiftUI
import DriveMapperCore

/// Node-link tree: the drive as a root box, folders branching below it.
///
/// Only expanded branches are laid out, which is what keeps this usable — a drive
/// can hold hundreds of thousands of folders and drawing them all would be an
/// unreadable hairball regardless of how fast it rendered.
struct GraphTreeView: View {
    let drive: Drive
    let store: Store

    @State private var root: TreeNode?
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var loadFailed = false

    /// Scale when the current pinch began. A magnify gesture reports *cumulative*
    /// magnification on every change, so it has to multiply against the scale at
    /// gesture start — folding it into the live scale each time compounds
    /// exponentially and makes zooming impossible to control.
    @State private var pinchStartScale: CGFloat = 1.0

    /// Frame in window coordinates, so the scroll monitor can tell whether the
    /// pointer is over the graph rather than the sidebar.
    @State private var viewFrame: CGRect = .zero
    @State private var scrollMonitor: Any?

    private let minScale: CGFloat = 0.2
    private let maxScale: CGFloat = 3.0

    /// Ceiling on how many boxes the initial expand-all will lay out.
    private let expandBudget = 2000

    @State private var budgetReached = false
    /// Bumped by whole-tree actions (expand-all, collapse) to request a refit
    /// against the layout those actions produce.
    @State private var fitRequest = 0
    /// Zoom-to-fit runs once per drive, not on every layout pass — otherwise it
    /// would fight the user every time they expanded a node.
    @State private var didFitOnLoad = false

    /// extension -> colour slot, assigned per drive from its top file types —
    /// the same mapping the treemap uses, so a colour means the same thing in
    /// both views.
    @State private var palette: [String: Int] = [:]
    @State private var legend: [(ext: String, slot: Int)] = []

    /// Top-down puts every sibling in its own column, so a drive whose folders
    /// are mostly at the top level becomes one very long horizontal line.
    /// Left-to-right stacks siblings vertically instead, which scrolls naturally.
    @AppStorage("graphHorizontal") private var horizontal = true

    /// Beyond this many siblings the layout stops being readable and starts being
    /// slow, so the rest collapse into a single "N more" marker.
    private let maxChildrenPerNode = 40

    private let nodeWidth: CGFloat = 148
    private let nodeHeight: CGFloat = 46
    private let hGap: CGFloat = 18
    private let vGap: CGFloat = 46

    var body: some View {
        Group {
            if let root {
                graph(root: root)
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

    @ViewBuilder
    private func graph(root: TreeNode) -> some View {
        // Same shell as the treemap: map on top, full-width legend bar along the
        // bottom — so the colour key sits in the same place in both views. This
        // VStack shape is safe in a split-view detail (the treemap proves it);
        // the balloon bug came from fixed content stacked above a List, and the
        // GeometryReader here is flexible.
        VStack(spacing: 0) {
            mapArea(root: root)
            Divider()
            legendBar
        }
    }

    private var legendBar: some View {
        HStack {
            ExtensionLegendView(legend: legend, includesDrive: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func mapArea(root: TreeNode) -> some View {
        let layout = buildLayout(root: root)

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)

                // Blender-style reference grid. Anchored in content space, so it
                // pans and zooms with the tree — a static grid reads as wallpaper,
                // a moving one tells you where you are.
                gridBackground(viewport: geo.size)

                ZStack(alignment: .topLeading) {
                    // Edges first so nodes paint over the line ends.
                    Canvas { context, _ in
                        for edge in layout.edges {
                            var path = Path()
                            // Orthogonal elbows read as a tree diagram; straight
                            // diagonals turn into visual noise once siblings fan out.
                            // The elbow turns on the axis the tree grows along.
                            path.move(to: edge.from)
                            if horizontal {
                                let midX = (edge.from.x + edge.to.x) / 2
                                path.addLine(to: CGPoint(x: midX, y: edge.from.y))
                                path.addLine(to: CGPoint(x: midX, y: edge.to.y))
                            } else {
                                let midY = (edge.from.y + edge.to.y) / 2
                                path.addLine(to: CGPoint(x: edge.from.x, y: midY))
                                path.addLine(to: CGPoint(x: edge.to.x, y: midY))
                            }
                            path.addLine(to: edge.to)
                            context.stroke(
                                path,
                                with: .color(.secondary.opacity(0.45)),
                                style: StrokeStyle(lineWidth: 1.2, lineJoin: .round)
                            )
                        }
                    }
                    .frame(width: layout.size.width, height: layout.size.height)

                    ForEach(layout.placements) { placement in
                        GraphNodeView(
                            placement: placement,
                            store: store,
                            palette: palette,
                            width: nodeWidth,
                            height: nodeHeight,
                            onToggle: { toggle(placement) }
                        )
                        .position(x: placement.center.x, y: placement.center.y)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(offset)
            }
            // Pin to the viewport before anything anchors to it.
            //
            // Without this the ZStack grows to fit the pannable content, which on
            // a large tree is far bigger than the window — and the controls
            // overlay then anchored to the *content's* bottom-right, landing
            // off-screen and getting clipped. That's why the bar vanished on big
            // trees and stayed put on small ones.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            // `simultaneousGesture` with a minimum distance, so a click on a node
            // isn't consumed by the pan. A plain `.gesture(DragGesture())` here
            // claimed the press before the node's tap could fire, which is why
            // clicking a box did nothing.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        offset = CGSize(
                            width: dragStart.width + value.translation.width,
                            height: dragStart.height + value.translation.height
                        )
                    }
                    .onEnded { _ in dragStart = offset }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        // Against the scale at gesture start, not the live one.
                        zoom(to: pinchStartScale * value.magnification,
                             around: value.startLocation)
                    }
                    .onEnded { _ in pinchStartScale = scale }
            )
            .onAppear {
                pinchStartScale = scale
                installScrollMonitor(viewport: geo.size)
            }
            // Fit via onChange(initial:), not onAppear: onAppear fires once, and
            // if the geometry isn't settled at that instant the fit is skipped
            // with no retry — entering Map mode then showed the tree at 100% with
            // the root parked off-screen. This re-attempts on every size pass
            // until one succeeds. Same lesson as the treemap's stale-size bug.
            .onChange(of: geo.size, initial: true) { _, newSize in
                if !didFitOnLoad, newSize.width > 40 {
                    didFitOnLoad = true
                    fitToViewport(layout: layout, viewport: newSize)
                }
            }
            // Refit when the layout changes shape wholesale. Orientation swaps
            // the depth and sibling axes, so the old pan/zoom point at
            // coordinates that no longer hold the tree — without this the graph
            // vanished until a manual Fit. These handlers run after the body
            // re-evaluates, so `layout` here is the NEW geometry, not the one
            // the button click saw.
            .onChange(of: horizontal) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    fitToViewport(layout: layout, viewport: geo.size)
                }
            }
            .onChange(of: fitRequest) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    fitToViewport(layout: layout, viewport: geo.size)
                }
            }
            .onDisappear { removeScrollMonitor() }
            .onChange(of: geo.frame(in: .global)) { _, frame in viewFrame = frame }
            .background(
                GeometryReader { inner in
                    Color.clear
                        .onAppear { viewFrame = inner.frame(in: .global) }
                }
            )
            // Controls at top-left; the legend owns the bottom edge as a
            // full-width bar (matching the treemap), so the two never collide.
            .overlay(alignment: .topLeading) {
                controls(layout: layout, viewport: geo.size)
            }
            // Initial framing is handled by the fit in the other onAppear — two
            // handlers both setting offset would race.
        }
        .clipped()
    }

    private func controls(layout: Layout, viewport: CGSize) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(layout.placements.count) nodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if budgetReached {
                    // Say so rather than leaving branches mysteriously shut.
                    Text("partly collapsed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("The tree is too large to lay out in full. Expand the remaining branches by clicking them.")
                }
            }
            .padding(.trailing, 4)

            Divider().frame(height: 16)

            // Words, not icons. The previous pair of mirrored-arrow glyphs were
            // near-indistinguishable at this size, and no tooltip fixes a control
            // you can't tell apart at a glance.
            Button("Expand all") {
                if let root { expandAll(from: root) }
                fitRequest += 1
            }
            .help("Open every branch, up to \(expandBudget) boxes")

            Button("Collapse") {
                if let root { collapseAll(from: root) }
                fitRequest += 1
            }
            .help("Close everything back to the drive's top level")

            Divider().frame(height: 16)

            Button {
                horizontal.toggle()
            } label: {
                Label(
                    horizontal ? "Sideways" : "Downward",
                    systemImage: horizontal
                        ? "arrow.right.to.line"
                        : "arrow.down.to.line"
                )
            }
            .help(horizontal
                  ? "Tree grows left-to-right. Click for top-down."
                  : "Tree grows top-down. Click for left-to-right.")

            Divider().frame(height: 16)

            // Finer than the old 1.25 steps — 1.15 gives roughly twice the
            // resolution over the same range.
            Button { zoom(by: 1 / 1.15, viewport: viewport) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(scale <= minScale + 0.001)
            .help("Zoom out (⌘−)")

            Button {
                withAnimation(.easeOut(duration: 0.12)) {
                    zoom(to: 1, around: CGPoint(x: viewport.width / 2, y: viewport.height / 2))
                }
                pinchStartScale = scale
            } label: {
                // Doubles as a readout and a reset-to-100% target.
                Text("\(Int(scale * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 38)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Current zoom. Click to reset to 100% (⌘0)")

            Button { zoom(by: 1.15, viewport: viewport) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            // "=" not "+", so it's ⌘= rather than ⌘⇧= on a US layout.
            .keyboardShortcut("=", modifiers: .command)
            .disabled(scale >= maxScale - 0.001)
            .help("Zoom in (⌘=)")

            Button("Fit") {
                withAnimation(.easeOut(duration: 0.2)) {
                    fitToViewport(layout: layout, viewport: viewport)
                }
            }
            .help("Scale and centre so the whole tree is visible")
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    // MARK: - Grid

    /// The reference grid behind the tree: a fine, single-weight mesh.
    ///
    /// Lines live in content coordinates — the same space the boxes are laid out
    /// in — so panning slides the grid and zooming visibly tightens or spreads
    /// it. The step only re-levels (doubles/halves) when on-screen spacing
    /// leaves a wide ≈9–54px band, so across most of the zoom range the mesh
    /// scales continuously with the content instead of snapping.
    ///
    /// Positions are computed by hand instead of putting the Canvas inside the
    /// scaled/offset layer — a transformed canvas would scale the stroke widths
    /// too, turning the grid to fog when zoomed out and planks when zoomed in.
    private func gridBackground(viewport: CGSize) -> some View {
        Canvas { context, size in
            var step = 48 * scale
            while step < 24 { step *= 2 }
            while step > 120 { step /= 2 }

            // One path, one stroke — every line identical.
            var path = Path()

            var x = offset.width.truncatingRemainder(dividingBy: step)
            if x < 0 { x += step }
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }

            var y = offset.height.truncatingRemainder(dividingBy: step)
            if y < 0 { y += step }
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }

            context.stroke(
                path,
                with: .color(.primary.opacity(0.06)),
                lineWidth: 1
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Zoom

    /// Sets an absolute zoom level, keeping `anchor` (a point in viewport
    /// coordinates) pinned to the same content it was over.
    ///
    /// Zooming around the pointer rather than the origin is most of what makes
    /// zoom feel controllable — otherwise the thing you're looking at slides away
    /// as you zoom toward it.
    private func zoom(to newScale: CGFloat, around anchor: CGPoint) {
        let clamped = min(max(minScale, newScale), maxScale)
        guard clamped != scale else { return }

        // Content point currently under the anchor, then re-solve offset so it
        // stays under the anchor at the new scale.
        let contentX = (anchor.x - offset.width) / scale
        let contentY = (anchor.y - offset.height) / scale
        offset = CGSize(
            width: anchor.x - contentX * clamped,
            height: anchor.y - contentY * clamped
        )
        scale = clamped
        dragStart = offset
    }

    /// Button/keyboard zoom, anchored on the viewport centre.
    private func zoom(by factor: CGFloat, viewport: CGSize) {
        withAnimation(.easeOut(duration: 0.12)) {
            zoom(
                to: scale * factor,
                around: CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            )
        }
        pinchStartScale = scale
    }

    // MARK: - Trackpad

    /// Two-finger scroll to pan, pinch or ⌘/⌃-scroll to zoom.
    ///
    /// Uses a local event monitor rather than an `NSView` subclass: SwiftUI draws
    /// its content into a single hosting view, so a background `NSView` never
    /// becomes the hit-test target for scroll events and would simply never see
    /// them. The monitor checks the pointer is actually over the graph before
    /// consuming anything, so scrolling the sidebar still scrolls the sidebar.
    private func installScrollMonitor(viewport: CGSize) {
        removeScrollMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            guard let window = event.window,
                  let contentView = window.contentView
            else { return event }

            // AppKit's origin is bottom-left; SwiftUI's global space is top-left.
            let point = CGPoint(
                x: event.locationInWindow.x,
                y: contentView.bounds.height - event.locationInWindow.y
            )
            guard viewFrame.contains(point) else { return event }

            let local = CGPoint(x: point.x - viewFrame.minX, y: point.y - viewFrame.minY)

            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                // Standard macOS zoom modifier. Small exponent keeps it gradual.
                let factor = 1 + (event.scrollingDeltaY * 0.005)
                zoom(to: scale * factor, around: local)
                pinchStartScale = scale
            } else {
                offset = CGSize(
                    width: offset.width + event.scrollingDeltaX,
                    height: offset.height + event.scrollingDeltaY
                )
                dragStart = offset
            }
            return nil  // consumed
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    /// Scales so the whole tree is visible, then centres it.
    ///
    /// With everything expanded by default the tree is usually larger than the
    /// window, so opening at 100% would drop you into a corner of it with no
    /// indication of how much lies off-screen.
    private func fitToViewport(layout: Layout, viewport: CGSize) {
        let bounds = layout.contentBounds
        guard bounds.width > 0, bounds.height > 0,
              viewport.width > 0, viewport.height > 0
        else { return }

        // Fits against the tight content bounds, so the tree fills the window
        // instead of leaving room for canvas padding that holds nothing.
        let margin: CGFloat = 16
        let fitScale = min(
            (viewport.width - margin * 2) / bounds.width,
            (viewport.height - margin * 2) / bounds.height
        )
        // Never zoom *in* past 100% to fit — a small tree should sit at natural
        // size rather than being blown up to fill the window.
        scale = min(max(minScale, min(fitScale, 1.0)), maxScale)
        pinchStartScale = scale

        // Centre the content rectangle, accounting for where it starts.
        offset = CGSize(
            width: (viewport.width - bounds.width * scale) / 2 - bounds.minX * scale,
            height: (viewport.height - bounds.height * scale) / 2 - bounds.minY * scale
        )
        dragStart = offset
    }


    private func toggle(_ placement: Placement) {
        guard case .folder(let node) = placement.kind, node.hasChildren else { return }
        node.loadChildrenIfNeeded(store: store)
        withAnimation(.easeOut(duration: 0.18)) {
            node.isExpanded.toggle()
        }
    }

    private func load() {
        loadFailed = false
        root = nil
        didFitOnLoad = false
        guard let driveId = drive.id,
              let rootFolder = try? store.rootFolder(driveId: driveId)
        else {
            loadFailed = true
            return
        }

        // Same slot assignment as the treemap: the drive's four biggest file
        // types get the validated hues, everything else is "Other".
        let top = (try? store.topExtensions(driveId: driveId, limit: TreemapPalette.slotCount)) ?? []
        palette = Dictionary(uniqueKeysWithValues: top.enumerated().map { ($0.element.ext, $0.offset) })
        legend = top.enumerated().map { (ext: $0.element.ext, slot: $0.offset) }

        let node = TreeNode(folder: rootFolder, hasChildren: true)
        if let rootId = rootFolder.id,
           let dominant = try? store.dominantExtensions(for: [rootId]) {
            node.dominantExt = dominant[rootId]
        }
        // Just the drive's top level. Expanding everything on load made even a
        // modest drive open as a wall of boxes; the expand-all button is there
        // when you want it.
        node.loadChildrenIfNeeded(store: store)
        node.isExpanded = true
        budgetReached = false
        root = node
    }

    /// Expands the whole tree, breadth-first, up to a node budget.
    ///
    /// Breadth-first so the budget buys complete shallow levels rather than one
    /// deep chain. The budget matters even though a typical drive here is a few
    /// hundred folders: an archive drive can hold hundreds of thousands, and
    /// laying every one out would wedge the window. Anything past the budget stays
    /// collapsed with its "+" badge and can be opened by hand.
    private func expandAll(from root: TreeNode) {
        var drawn = 1
        var queue = [root]
        var head = 0
        var truncated = false

        while head < queue.count {
            let node = queue[head]
            head += 1
            guard node.hasChildren else { continue }

            node.loadChildrenIfNeeded(store: store)
            guard let children = node.children, !children.isEmpty else { continue }

            // Only the first `maxChildrenPerNode` get drawn, plus one overflow
            // marker — so count what would actually be laid out, not what exists.
            let wouldDraw = min(children.count, maxChildrenPerNode)
                + (children.count > maxChildrenPerNode ? 1 : 0)

            // Stop before a level rather than halfway through it; a partially
            // expanded row looks like a bug.
            guard drawn + wouldDraw <= expandBudget else {
                truncated = true
                break
            }

            node.isExpanded = true
            drawn += wouldDraw
            queue.append(contentsOf: children)
        }

        budgetReached = truncated
    }

    private func collapseAll(from root: TreeNode) {
        func walk(_ node: TreeNode) {
            node.isExpanded = false
            for child in node.children ?? [] { walk(child) }
        }
        walk(root)
        // Keep the drive's own children visible; a single lonely box is useless.
        root.isExpanded = true
        budgetReached = false
    }

    // MARK: - Layout

    struct Layout {
        var placements: [Placement]
        var edges: [Edge]
        /// Canvas the nodes are positioned within.
        var size: CGSize
        /// Tight rectangle around the actual boxes.
        ///
        /// Distinct from `size` because zoom-to-fit must scale against the real
        /// content, not the canvas — padding the canvas made the fit scale down to
        /// accommodate empty space, so the tree opened smaller than it needed to.
        var contentBounds: CGRect
    }

    struct Edge {
        var from: CGPoint
        var to: CGPoint
    }

    struct Placement: Identifiable {
        enum Kind {
            case folder(TreeNode)
            /// Stand-in for sibling folders we chose not to draw. Carries them so
            /// hovering can still say what they are.
            case overflow(hidden: [TreeNode])
        }
        let id: String
        var kind: Kind
        var center: CGPoint
        var depth: Int
    }

    /// Tidy-tree layout: every visible leaf gets its own column, and each parent
    /// sits centered over its children. Simple, deterministic, and good enough for
    /// the node counts that stay readable.
    private func buildLayout(root: TreeNode) -> Layout {
        var placements: [Placement] = []
        var edges: [Edge] = []
        var nextSibling: CGFloat = 0

        // The layout is computed on two abstract axes — "depth" (how far from the
        // root) and "sibling" (position among peers) — then mapped to x/y at the
        // end. That's what lets the same algorithm serve both orientations.
        let depthStride = horizontal ? nodeWidth + 64 : nodeHeight + vGap
        let siblingStride = horizontal ? nodeHeight + 12 : nodeWidth + hGap
        let siblingExtent = horizontal ? nodeHeight : nodeWidth

        func point(depth: CGFloat, sibling: CGFloat) -> CGPoint {
            horizontal ? CGPoint(x: depth, y: sibling) : CGPoint(x: sibling, y: depth)
        }

        @discardableResult
        func place(_ node: TreeNode, depth: Int) -> CGPoint {
            let depthPos = CGFloat(depth) * depthStride + (horizontal ? nodeWidth : nodeHeight) / 2

            let visibleChildren: [TreeNode]
            var hiddenChildren: [TreeNode] = []
            if node.isExpanded, let children = node.children, !children.isEmpty {
                if children.count > maxChildrenPerNode {
                    // Sort by size before truncating. Children arrive in name
                    // order, so cutting the tail hid an arbitrary alphabetical
                    // slice — the biggest folder on the drive could vanish for
                    // starting with "z". Now the cap drops the smallest.
                    let bySize = children.sorted { $0.folder.totalBytes > $1.folder.totalBytes }
                    visibleChildren = Array(bySize.prefix(maxChildrenPerNode))
                    hiddenChildren = Array(bySize.dropFirst(maxChildrenPerNode))
                } else {
                    visibleChildren = children
                }
            } else {
                visibleChildren = []
            }

            guard !visibleChildren.isEmpty || !hiddenChildren.isEmpty else {
                // Leaf: consume the next slot on the sibling axis.
                let center = point(depth: depthPos, sibling: nextSibling + siblingExtent / 2)
                nextSibling += siblingStride
                placements.append(Placement(
                    id: "f\(node.id)", kind: .folder(node), center: center, depth: depth
                ))
                return center
            }

            var childCenters: [CGPoint] = []
            for child in visibleChildren {
                childCenters.append(place(child, depth: depth + 1))
            }
            if !hiddenChildren.isEmpty {
                let center = point(
                    depth: CGFloat(depth + 1) * depthStride + (horizontal ? nodeWidth : nodeHeight) / 2,
                    sibling: nextSibling + siblingExtent / 2
                )
                nextSibling += siblingStride
                placements.append(Placement(
                    id: "o\(node.id)",
                    kind: .overflow(hidden: hiddenChildren),
                    center: center,
                    depth: depth + 1
                ))
                childCenters.append(center)
            }

            // Parent centered over the span of its children, on the sibling axis.
            let siblingValues = childCenters.map { horizontal ? $0.y : $0.x }
            let mid = ((siblingValues.min() ?? 0) + (siblingValues.max() ?? 0)) / 2
            let center = point(depth: depthPos, sibling: mid)

            for childCenter in childCenters {
                edges.append(Edge(
                    from: horizontal
                        ? CGPoint(x: center.x + nodeWidth / 2, y: center.y)
                        : CGPoint(x: center.x, y: center.y + nodeHeight / 2),
                    to: horizontal
                        ? CGPoint(x: childCenter.x - nodeWidth / 2, y: childCenter.y)
                        : CGPoint(x: childCenter.x, y: childCenter.y - nodeHeight / 2)
                ))
            }

            placements.append(Placement(
                id: "f\(node.id)", kind: .folder(node), center: center, depth: depth
            ))
            return center
        }

        place(root, depth: 0)

        // Shallowest first, so the root is placements[0].
        placements.sort { $0.depth < $1.depth }

        // Centres, so the real extent is half a box further out on each side.
        let minX = placements.map(\.center.x).min() ?? 0
        let maxX = placements.map(\.center.x).max() ?? 0
        let minY = placements.map(\.center.y).min() ?? 0
        let maxY = placements.map(\.center.y).max() ?? 0

        let bounds = CGRect(
            x: minX - nodeWidth / 2,
            y: minY - nodeHeight / 2,
            width: (maxX - minX) + nodeWidth,
            height: (maxY - minY) + nodeHeight
        )

        return Layout(
            placements: placements,
            edges: edges,
            // Just enough to hold the boxes without clipping them.
            size: CGSize(
                width: maxX + nodeWidth / 2 + 8,
                height: maxY + nodeHeight / 2 + 8
            ),
            contentBounds: bounds
        )
    }
}

// MARK: - Node

struct GraphNodeView: View {
    let placement: GraphTreeView.Placement
    let store: Store
    let palette: [String: Int]
    let width: CGFloat
    let height: CGFloat
    let onToggle: () -> Void

    @State private var isHovered = false
    @State private var showPopover = false

    @State private var showOverflowPopover = false

    var body: some View {
        switch placement.kind {
        case .overflow(let hidden):
            overflowBox(hidden: hidden)
        case .folder(let node):
            folderBox(node: node)
        }
    }

    private func overflowBox(hidden: [TreeNode]) -> some View {
        VStack(spacing: 1) {
            Text("+\(hidden.count) folders")
                .font(.caption.weight(.medium))
            Text(formatBytes(hidden.reduce(0) { $0 + $1.folder.totalBytes }))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
                .strokeBorder(.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { showOverflowPopover = $0 }
        .popover(isPresented: $showOverflowPopover, arrowEdge: .trailing) {
            OverflowBreakdownView(hidden: hidden)
        }
    }

    private func folderBox(node: TreeNode) -> some View {
        // Button rather than `.onTapGesture`, for the same first-click-is-eaten
        // reason as the list rows.
        Button(action: onToggle) {
            boxContent(node: node)
        }
        .buttonStyle(.plain)
    }

    private func boxContent(node: TreeNode) -> some View {
        // Same fill and ink rules as the treemap tiles: slot colour from the
        // drive's palette, text in whichever ink reads on that fill. Ink instead
        // of semantic colours everywhere inside the box — .secondary on a
        // saturated fill is unreadable.
        //
        // The root gets the reserved drive colour instead of its dominant file
        // type: coloured by content, the drive read as just another folder.
        let isRoot = node.folder.parentId == nil
        let slot = node.dominantExt.flatMap { palette[$0] } ?? -1
        let fill = isRoot ? TreemapPalette.driveRoot : TreemapPalette.color(slot: slot)
        let ink = isRoot ? TreemapPalette.driveRootInk : TreemapPalette.ink(onSlot: slot)

        return VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: node.folder.isLeafBundle
                      ? "shippingbox.fill"
                      : (node.folder.parentId == nil ? "externaldrive.fill" : "folder.fill"))
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.85))
                Text(node.folder.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(ink)
            }
            Text(sizeLabel(node))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(ink.opacity(0.75))
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(fill)
                .shadow(color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 5 : 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isHovered ? ink.opacity(0.9) : ink.opacity(0.2),
                    lineWidth: isHovered ? 1.6 : 1
                )
        )
        // The badge sits INSIDE the box bounds. It used to be drawn with
        // `.offset(y: 7)`, which put it outside the frame — and a view can't be
        // clicked outside its parent's bounds, so clicking the plus did nothing.
        .overlay(alignment: .bottomTrailing) {
            if node.hasChildren {
                Image(systemName: node.isExpanded ? "minus.circle.fill" : "plus.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(ink.opacity(0.9))
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        // Hit area covers the whole box including the badge. The Button wrapper
        // handles the click.
        .contentShape(RoundedRectangle(cornerRadius: 8))
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

    private func sizeLabel(_ node: TreeNode) -> String {
        if node.folder.isLeafBundle && node.folder.totalBytes == 0 {
            return "not indexed"
        }
        return formatBytes(node.folder.totalBytes)
    }
}

/// What the "+N folders" marker is standing in for.
///
/// These are sibling *folders* past the per-node draw cap — not loose files.
/// Files never appear as nodes; they show up as extension counts on the folder
/// that holds them.
struct OverflowBreakdownView: View {
    let hidden: [TreeNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(hidden.count) more folders")
                .font(.headline)
            Text("Smallest siblings, not drawn to keep the map readable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(hidden.prefix(12)) { node in
                HStack(spacing: 8) {
                    Image(systemName: node.folder.isLeafBundle ? "shippingbox" : "folder")
                        .font(.caption2)
                        .foregroundStyle(node.folder.isLeafBundle ? Color.secondary : AppColor.accent)
                    Text(node.folder.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 10)
                    Text(node.folder.isLeafBundle && node.folder.totalBytes == 0
                         ? "not indexed"
                         : formatBytes(node.folder.totalBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if hidden.count > 12 {
                Text("…and \(hidden.count - 12) more — switch to the list view to see them all")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .topLeading)
    }
}
