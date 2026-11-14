import Sempere
import SempereAppCore
import SempereInsights
import SwiftUI

// The mind map of related notes (docs/design/1.2-note-insights.md §6 item 5, §3.8, D9; Insights PR 3): the work
// device's note-cluster map, drawn in one `Canvas` (never one view per note: the iPhone draws up to 1,500 notes, other
// devices 4,000). Labeled cluster regions with the two levels as zoom levels, edges of the related graph, notes placed
// on this device dashed, a banner when this device draws its own map; pan, pinch or the zoom buttons, tap a note to
// open it, tap a region to zoom into it. The geometry and the level of detail are the model's (`InsightsMapLayout`,
// `MapDetail`, Linux-tested); this view only draws. VoiceOver reaches every cluster and note through the list form
// (the grouped list, shown by default while VoiceOver runs) and the map's own cluster elements.

/// The map with its list form and banners: the content of the map sheet and of Settings ▸ Note Insights' link.
struct InsightsMapScreen: View {
    @AppModelEnvironment private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Opens a note (the sheet also closes itself).
    var onOpen: (UUID) -> Void
    @State private var form: Form?

    enum Form: String, Hashable { case map, list }

    var body: some View {
        let map = model.insightsMap
        let shown = form ?? (voiceOver ? .list : .map)
        VStack(spacing: 0) {
            Picker("Show", selection: Binding(get: { shown }, set: { form = $0 })) {
                Text("Map", comment: "The map of related notes, drawn").tag(Form.map)
                Text("List", comment: "The map of related notes, as a list of groups").tag(Form.list)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("insightsMap.form")
            if map.isLocal {
                banner(String(localized: "This device builds its own map: its numbers differ from the work device's. Groups and places may differ from other devices."),
                       systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("insightsMap.localBanner")
            } else if map.placedCount > 0, shown == .map {
                banner(String(localized: "Dashed notes are placed on this device; they join the shared map at its next rebuild."),
                       systemImage: "circle.dashed")
            }
            if map.isEmpty {
                ContentUnavailableView("No Map Yet", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("The map appears once the work device has built it."))
                    .frame(maxHeight: .infinity)
            } else if shown == .map {
                InsightsMapCanvas(map: map, onOpen: onOpen)
            } else {
                InsightsClustersList(onOpen: onOpen)
            }
        }
        .navigationTitle("Map of Related Notes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func banner(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
    }
}

/// The map as a sheet of its own (the sidebar's All Notes menu).
struct InsightsMapSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InsightsMapScreen { id in
                model.selectedNoteID = id
                dismiss()
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // A drag pans the map; it never pulls the sheet down (Done closes it).
        .interactiveDismissDisabled()
    }
}

/// The drawn map: pan, pinch, zoom buttons, tap to open a note or zoom into a region.
struct InsightsMapCanvas: View {
    @AppModelEnvironment private var model
    let map: InsightsMapLayout
    var onOpen: (UUID) -> Void

    /// On-screen points per unit of the map's square, and where the square's origin is on screen. Nil until the
    /// first layout (then the fit), and back to nil with "Fit".
    @State private var scale: CGFloat?
    @State private var origin: CGPoint = .zero
    /// The pinch and the drag in progress.
    @State private var pinch: (start: CGFloat, anchor: CGPoint, origin: CGPoint)?
    @State private var dragStart: CGPoint?

    static let palette: [SwiftUI.Color] = [.blue, .orange, .red, .teal, .green, .yellow, .purple, .pink, .brown, .indigo]
    static func color(_ id: Int?) -> SwiftUI.Color { id.map { palette[abs($0) % palette.count] } ?? .gray }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let fit = Self.fitScale(size)
            let s = scale ?? fit
            let o = scale == nil ? Self.fitOrigin(size) : origin
            // The notes by id, looked up only for the titles a frame draws (at most `MapDetail.titleLimit`).
            let notes = model.notesByID
            let selected = model.selectedNoteID.flatMap { map.index[$0] }
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                draw(in: &context, size: canvasSize, scale: s, origin: o, fit: fit, notes: notes, selected: selected)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(scale: s, origin: o))
            .simultaneousGesture(pinchGesture(size: size, scale: s, origin: o, fit: fit))
            .onTapGesture(coordinateSpace: .local) { point in tap(point, scale: s, origin: o, size: size) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Map of related notes"))
            .accessibilityChildren {
                // Each cluster: its label and size; activating it zooms there (the List form has every note).
                ForEach(map.regions.filter { $0.level == 0 && !$0.isOther }) { r in
                    Button {
                        zoom(to: r, size: size, fit: fit)
                    } label: {
                        Text("Group: \(r.label.joined(separator: ", ")); notes: \(r.count)",
                             comment: "VoiceOver: a group of the map of related notes (its label words, its number of notes; a count after a colon) [not-plural]")
                    }
                }
            }
            .accessibilityIdentifier("insightsMap.canvas")
            .clipped()
            // After the canvas's accessibility children, which replace the children of the view they are on: the zoom
            // buttons stay elements of their own.
            .overlay(alignment: .bottomTrailing) { zoomButtons(size: size, scale: s, origin: o, fit: fit) }
        }
    }

    // MARK: Geometry

    static func fitScale(_ size: CGSize) -> CGFloat { max(1, min(size.width, size.height)) }
    static func fitOrigin(_ size: CGSize) -> CGPoint {
        let s = fitScale(size)
        return CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
    }
    static let maxZoom: CGFloat = 40

    private func screen(_ x: Double, _ y: Double, _ s: CGFloat, _ o: CGPoint) -> CGPoint {
        CGPoint(x: o.x + CGFloat(x) * s, y: o.y + CGFloat(y) * s)
    }

    // MARK: Drawing

    /// The notes on screen (with a margin so dots and labels at the edge are drawn) and the level of detail they get.
    private func onScreen(size: CGSize, scale s: CGFloat, origin o: CGPoint, fit: CGFloat) -> (visible: [Int], detail: MapDetail) {
        let pad = 24 / s
        let x0 = Double((0 - o.x) / s - pad), x1 = Double((size.width - o.x) / s + pad)
        let y0 = Double((0 - o.y) / s - pad), y1 = Double((size.height - o.y) / s + pad)
        let visible = map.nodes(inX: x0, x1, y: y0, y1)
        let hasGroups = map.regions.contains { $0.level == 1 }
        return (visible, MapDetail.at(pointsPerUnit: Double(s), visibleNotes: visible.count, hasGroups: hasGroups, fitSide: Double(fit)))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, scale s: CGFloat, origin o: CGPoint, fit: CGFloat,
                      notes: [UUID: NoteSummary], selected: Int?) {
        let (visible, detail) = onScreen(size: size, scale: s, origin: o, fit: fit)
        // Regions of the level this zoom shows.
        let regions = map.regions.filter { $0.level == detail.regionLevel && !$0.isOther }
        for r in regions {
            let c = screen(r.x, r.y, s, o), rad = CGFloat(r.radius) * s
            let rect = CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad)
            guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
            let color = Self.color(r.id)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.08)))
            context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.35)), lineWidth: 1)
        }
        // Edges: one path, those with an end on screen, from the neighbors of what is on screen (never every edge).
        if detail.edges, !map.edges.isEmpty {
            var path = Path()
            for e in map.edges(touching: visible) {
                let a = map.nodes[Int(e.a)], b = map.nodes[Int(e.b)]
                path.move(to: screen(a.x, a.y, s, o))
                path.addLine(to: screen(b.x, b.y, s, o))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 0.6)
        }
        // The selected note's edges stand out.
        if let selected, map.neighbors.indices.contains(selected) {
            var path = Path()
            let n = map.nodes[selected]
            for j in map.neighbors[selected] {
                let other = map.nodes[Int(j)]
                path.move(to: screen(n.x, n.y, s, o))
                path.addLine(to: screen(other.x, other.y, s, o))
            }
            context.stroke(path, with: .color(.accentColor.opacity(0.8)), lineWidth: 1.5)
        }
        // Notes: one fill per color, placed notes dashed.
        let r = CGFloat(detail.dot)
        var fills: [Int?: Path] = [:]
        var placed = Path()
        for i in visible {
            let n = map.nodes[i]
            let p = screen(n.x, n.y, s, o)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            if n.placed {
                placed.addEllipse(in: rect)
            } else {
                fills[map.colorKey(i, level: detail.regionLevel), default: Path()].addEllipse(in: rect)
            }
        }
        for (key, path) in fills { context.fill(path, with: .color(Self.color(key))) }
        if !placed.isEmpty {
            context.fill(placed, with: .color(.secondary.opacity(0.25)))
            context.stroke(placed, with: .color(.primary.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        if let selected {
            let n = map.nodes[selected]
            let p = screen(n.x, n.y, s, o)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6)),
                           with: .color(.accentColor), lineWidth: 2)
        }
        // Note titles (zoomed far in, few notes on screen; vault data, never translated), skipping one that would overlap
        // another title.
        if detail.titles {
            var placedTitles: [CGRect] = []
            for i in visible.prefix(MapDetail.titleLimit) {
                guard let title = notes[map.nodes[i].id].map({ NoteTitle.display($0.title) }), !title.isEmpty else { continue }
                let n = map.nodes[i]
                let p = screen(n.x, n.y, s, o)
                let text = context.resolve(Text(verbatim: title).font(.caption2).foregroundStyle(.primary))
                let size = text.measure(in: CGSize(width: 200, height: 40))
                let box = CGRect(x: p.x + r + 3, y: p.y - size.height / 2, width: size.width, height: size.height)
                guard !placedTitles.contains(where: { $0.intersects(box) }) else { continue }
                placedTitles.append(box)
                context.draw(text, in: box)
            }
        }
        // Region labels, largest first, never overlapping one another.
        var taken: [CGRect] = []
        for region in regions.sorted(by: { $0.count > $1.count }) {
            let c = screen(region.x, region.y, s, o)
            guard CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -20).contains(c), CGFloat(region.radius) * s >= 18 else { continue }
            let label = region.label.prefix(3).joined(separator: ", ")
            guard !label.isEmpty else { continue }
            let text = context.resolve(Text(verbatim: label).font(detail.regionLevel == 1 ? .subheadline.bold() : .caption.bold())
                .foregroundStyle(.primary))
            let measured = text.measure(in: CGSize(width: 220, height: 60))
            let box = CGRect(x: c.x - measured.width / 2 - 6, y: c.y - measured.height / 2 - 3, width: measured.width + 12,
                             height: measured.height + 6)
            guard !taken.contains(where: { $0.intersects(box) }) else { continue }
            taken.append(box)
            context.fill(Path(roundedRect: box, cornerRadius: 6), with: .style(.background.opacity(0.85)))
            context.draw(text, in: box.insetBy(dx: 6, dy: 3))
        }
    }

    // MARK: Gestures

    private func dragGesture(scale s: CGFloat, origin o: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                // A pinch moves the map itself; the drag picks up again (from where the pinch left it) once it ends.
                guard pinch == nil else { return }
                let start = dragStart ?? o
                if dragStart == nil { dragStart = o; if scale == nil { scale = s } }
                origin = CGPoint(x: start.x + v.translation.width, y: start.y + v.translation.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func pinchGesture(size: CGSize, scale s: CGFloat, origin o: CGPoint, fit: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let p = pinch ?? (start: s, anchor: CGPoint(x: v.startAnchor.x * size.width, y: v.startAnchor.y * size.height), origin: o)
                if pinch == nil { pinch = p }
                let new = min(fit * Self.maxZoom, max(fit * 0.5, p.start * v.magnification))
                // Keep the map point under the pinch's anchor in place.
                let k = new / p.start
                origin = CGPoint(x: p.anchor.x - (p.anchor.x - p.origin.x) * k, y: p.anchor.y - (p.anchor.y - p.origin.y) * k)
                scale = new
            }
            .onEnded { _ in pinch = nil; dragStart = nil }
    }

    /// A tap: at the groups' level it zooms into the group; closer in it opens the note whose dot it hits, else zooms
    /// into the cluster around it (`InsightsMapLayout.tapTarget`).
    private func tap(_ point: CGPoint, scale s: CGFloat, origin o: CGPoint, size: CGSize) {
        let fit = Self.fitScale(size)
        let detail = onScreen(size: size, scale: s, origin: o, fit: fit).detail
        let target = map.tapTarget(x: Double((point.x - o.x) / s), y: Double((point.y - o.y) / s), pointsPerUnit: Double(s), detail: detail)
        switch target {
        case .note(let i): onOpen(map.nodes[i].id)
        case .region(let r): withAnimation(.easeInOut(duration: 0.3)) { zoom(to: r, size: size, fit: fit) }
        case .nothing: break
        }
    }

    private func zoom(to r: InsightsMapLayout.Region, size: CGSize, fit: CGFloat) {
        let s = CGFloat(InsightsMapLayout.pointsPerUnit(toFit: r, side: Double(fit), maxScale: Double(fit * Self.maxZoom)))
        scale = s
        origin = CGPoint(x: size.width / 2 - CGFloat(r.x) * s, y: size.height / 2 - CGFloat(r.y) * s)
    }

    private func zoomBy(_ k: CGFloat, size: CGSize, scale s: CGFloat, origin o: CGPoint, fit: CGFloat) {
        let new = min(fit * Self.maxZoom, max(fit * 0.5, s * k))
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        withAnimation(.easeInOut(duration: 0.2)) {
            origin = CGPoint(x: c.x - (c.x - o.x) * new / s, y: c.y - (c.y - o.y) * new / s)
            scale = new
        }
    }

    private func zoomButtons(size: CGSize, scale s: CGFloat, origin o: CGPoint, fit: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button { zoomBy(1.6, size: size, scale: s, origin: o, fit: fit) } label: {
                Image(systemName: "plus").frame(width: 36, height: 36)
            }
            .accessibilityLabel(Text("Zoom In"))
            .help("Zoom in")
            .accessibilityIdentifier("insightsMap.zoomIn")
            Divider().frame(width: 36)
            Button { zoomBy(1 / 1.6, size: size, scale: s, origin: o, fit: fit) } label: {
                Image(systemName: "minus").frame(width: 36, height: 36)
            }
            .accessibilityLabel(Text("Zoom Out"))
            .help("Zoom out")
            Divider().frame(width: 36)
            Button { withAnimation(.easeInOut(duration: 0.2)) { scale = nil } } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass").frame(width: 36, height: 36)
            }
            .accessibilityLabel(Text("Show the Whole Map"))
            .help("Show the whole map")
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }
}

/// The map's groups as a list (design §6 item 5, D9's fallback; the accessible and compact form): each group's label
/// and its notes; a tap opens one. Notes placed on this device (not in the work device's map yet) are marked.
struct InsightsClustersList: View {
    @AppModelEnvironment private var model
    var onOpen: (UUID) -> Void

    var body: some View {
        List {
            let clusters = model.insightsClusters
            if clusters.isEmpty {
                Text("No groups yet: they appear once the work device has built the map.").foregroundStyle(.secondary)
            }
            ForEach(clusters) { c in
                Section {
                    ForEach(c.members, id: \.self) { id in
                        Button {
                            onOpen(id)
                        } label: {
                            HStack {
                                Text(verbatim: NoteTitle.display(model.notesByID[id]?.title ?? "")).foregroundStyle(.primary)
                                Spacer()
                                if c.placed.contains(id) {
                                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                                        .accessibilityLabel("Placed on this device")
                                }
                            }
                        }
                        .help("Open this note")
                    }
                } header: {
                    Text(verbatim: c.label.joined(separator: ", "))
                }
            }
        }
    }
}
