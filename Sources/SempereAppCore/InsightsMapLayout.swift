import Foundation
import SempereInsights

// MARK: - The mind map's geometry (docs/design/1.2-note-insights.md §6 item 5, §3.8; Insights PR 3)
//
// What the app's map view draws, computed once per index refresh and never per frame: the notes of the work device's map
// (plus the notes this device placed itself) in a unit square, the two levels of cluster regions with their labels, the
// related graph's edges as index pairs, and a grid for hit-testing and culling, so a frame with thousands of notes
// touches only what is on screen. Level of detail (`MapDetail`) is a pure function of the zoom, so the view draws one
// `Canvas` and never one view per note. Linux-tested (`InsightsMapLayoutTests`).

/// The map as the app draws it.
public struct InsightsMapLayout: Sendable, Equatable {
    /// One note: its place in the unit square (y down), its level-0 cluster and level-1 group, and whether this device
    /// placed it (a dashed outline, design §3.8).
    public struct Node: Sendable, Equatable {
        public var id: UUID
        public var x: Double
        public var y: Double
        /// The level-0 cluster (nil: in no cluster).
        public var cluster: Int?
        /// The level-1 group the cluster belongs to (nil: none).
        public var group: Int?
        public var placed: Bool
    }

    /// A labeled cluster region: the circle around its members (center and radius in the unit square).
    public struct Region: Sendable, Equatable, Identifiable {
        public var id: Int
        /// 0: a cluster; 1: a group of clusters (the zoomed-out view).
        public var level: Int
        public var parent: Int?
        public var label: [String]
        public var x: Double
        public var y: Double
        public var radius: Double
        /// Notes in the region on this device.
        public var count: Int
        /// The "Other" cluster of notes too few to group (`MapBuilder.otherId`): drawn without a region.
        public var isOther: Bool
    }

    public var nodes: [Node]
    public var regions: [Region]
    /// The related graph's edges between nodes (indices into `nodes`, `a < b`, each pair once).
    public var edges: [Edge]
    /// Each node's neighbors by the edges (indices into `nodes`), so a frame draws the edges of what is on screen and
    /// the selected note's without walking every edge.
    public var neighbors: [[Int32]]
    /// `shared` (the work device's map, maybe with notes placed here) or `local` (this device's own map: the banner).
    public var basis: String
    /// Notes of each node index by id.
    public var index: [UUID: Int]
    /// The hit-testing and culling grid: `gridSize` x `gridSize` cells of node indices.
    public var grid: [[Int32]]
    public static let gridSize = 32

    public struct Edge: Sendable, Equatable, Hashable {
        public var a: Int32
        public var b: Int32
    }

    public var isEmpty: Bool { nodes.isEmpty }
    /// This device draws its own map (incompatible numbers; design §3.8): the view says so in a banner.
    public var isLocal: Bool { basis == "local" }
    public var placedCount: Int { nodes.reduce(0) { $0 + ($1.placed ? 1 : 0) } }

    public static let empty = InsightsMapLayout(nodes: [], regions: [], edges: [], basis: "none", index: [:], grid: [])

    public init(nodes: [Node], regions: [Region], edges: [Edge], basis: String, index: [UUID: Int], grid: [[Int32]]) {
        self.nodes = nodes; self.regions = regions; self.edges = edges; self.basis = basis; self.index = index; self.grid = grid
        neighbors = Self.neighbors(of: edges, count: nodes.count)
    }

    static func neighbors(of edges: [Edge], count: Int) -> [[Int32]] {
        var out = Array(repeating: [Int32](), count: count)
        for e in edges where Int(e.a) < count && Int(e.b) < count { out[Int(e.a)].append(e.b); out[Int(e.b)].append(e.a) }
        return out
    }

    /// The edges with an end among `shown` (node indices), each once.
    public func edges(touching shown: [Int]) -> [Edge] {
        let set = Set(shown)
        var out: [Edge] = []
        for i in shown where neighbors.indices.contains(i) {
            for j in neighbors[i] {
                // An edge between two shown notes is taken from its lower end only.
                if set.contains(Int(j)), Int(j) < i { continue }
                out.append(Edge(a: Int32(min(i, Int(j))), b: Int32(max(i, Int(j)))))
            }
        }
        return out
    }

    /// The layout of `view` (`InsightsReader.mapView`) with the related graph's `edges`. Positions are scaled into the
    /// unit square with a margin, keeping their aspect; a local map's notes are never "placed" (the banner says it).
    public init(view: InsightsReader.MapView, edges graphEdges: [UUID: [RelatedEdge]]?) {
        basis = view.basis
        let parents = Dictionary(view.clusters.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        var raw: [Node] = []
        raw.reserveCapacity(view.nodes.count)
        for n in view.nodes {
            guard let id = UUID(uuidString: n.note), n.x.isFinite, n.y.isFinite else { continue }
            raw.append(Node(id: id, x: n.x, y: n.y, cluster: n.cluster, group: n.cluster.flatMap { parents[$0] ?? nil },
                            placed: n.placed && view.basis != "local"))
        }
        // Scale into [margin, 1 - margin], the larger extent filling it, the other centered.
        let margin = 0.06
        if let minX = raw.map(\.x).min(), let maxX = raw.map(\.x).max(), let minY = raw.map(\.y).min(), let maxY = raw.map(\.y).max() {
            let extent = max(maxX - minX, maxY - minY, 1e-9)
            let s = (1 - 2 * margin) / extent
            let ox = margin + ((1 - 2 * margin) - (maxX - minX) * s) / 2, oy = margin + ((1 - 2 * margin) - (maxY - minY) * s) / 2
            for i in raw.indices {
                raw[i].x = raw.count == 1 ? 0.5 : ox + (raw[i].x - minX) * s
                raw[i].y = raw.count == 1 ? 0.5 : oy + (raw[i].y - minY) * s
            }
        }
        nodes = raw
        var index: [UUID: Int] = [:]
        for (i, n) in raw.enumerated() { index[n.id] = i }
        self.index = index
        // Regions: the members' mean, and a radius that covers most of them (the 90th percentile distance, so one far
        // member does not blow the circle up), at least a node's reach.
        var members0: [Int: [Int]] = [:], members1: [Int: [Int]] = [:]
        for (i, n) in raw.enumerated() {
            if let c = n.cluster { members0[c, default: []].append(i) }
            if let g = n.group { members1[g, default: []].append(i) }
        }
        var regions: [Region] = []
        for c in view.clusters {
            guard let m = (c.level == 0 ? members0 : members1)[c.id], !m.isEmpty else { continue }
            let cx = m.reduce(0) { $0 + raw[$1].x } / Double(m.count), cy = m.reduce(0) { $0 + raw[$1].y } / Double(m.count)
            let d = m.map { hypot(raw[$0].x - cx, raw[$0].y - cy) }.sorted()
            let r = max(d[min(d.count - 1, Int(Double(d.count) * 0.9))] + 0.012, 0.02)
            regions.append(Region(id: c.id, level: c.level, parent: c.parent, label: c.label, x: cx, y: cy, radius: r, count: m.count,
                                  isOther: c.level == 0 && c.id == MapBuilder.otherId))
        }
        // Groups first (drawn under their clusters), then the larger regions, then by id.
        regions.sort { a, b in
            if a.level != b.level { return a.level > b.level }
            if a.count != b.count { return a.count > b.count }
            return a.id < b.id
        }
        self.regions = regions
        // Edges: each pair once, between notes on the map.
        var seen = Set<Edge>()
        var edges: [Edge] = []
        for (from, list) in graphEdges ?? [:] {
            guard let a = index[from] else { continue }
            for e in list {
                guard let b = index[e.note], a != b else { continue }
                let edge = Edge(a: Int32(min(a, b)), b: Int32(max(a, b)))
                if seen.insert(edge).inserted { edges.append(edge) }
            }
        }
        edges.sort { ($0.a, $0.b) < ($1.a, $1.b) }
        self.edges = edges
        neighbors = Self.neighbors(of: edges, count: raw.count)
        var grid = Array(repeating: [Int32](), count: Self.gridSize * Self.gridSize)
        for (i, n) in raw.enumerated() { grid[Self.cell(n.x, n.y)].append(Int32(i)) }
        self.grid = grid
    }

    static func cellCoordinate(_ v: Double) -> Int { min(gridSize - 1, max(0, Int((v * Double(gridSize)).rounded(.down)))) }
    static func cell(_ x: Double, _ y: Double) -> Int { cellCoordinate(y) * gridSize + cellCoordinate(x) }

    /// The node nearest to (`x`, `y`) in the unit square within `reach`, or nil.
    public func node(near x: Double, _ y: Double, reach: Double) -> Int? {
        guard !grid.isEmpty else { return nil }
        var best: (Int, Double)?
        let lo = (Self.cellCoordinate(x - reach), Self.cellCoordinate(y - reach)), hi = (Self.cellCoordinate(x + reach), Self.cellCoordinate(y + reach))
        for cy in lo.1...hi.1 {
            for cx in lo.0...hi.0 {
                for i in grid[cy * Self.gridSize + cx] {
                    let n = nodes[Int(i)]
                    let d = hypot(n.x - x, n.y - y)
                    if d <= reach, d < (best?.1 ?? .infinity) { best = (Int(i), d) }
                }
            }
        }
        return best?.0
    }

    /// The nodes inside the rectangle (unit square coordinates), from the grid: what a frame draws.
    public func nodes(inX x0: Double, _ x1: Double, y y0: Double, _ y1: Double) -> [Int] {
        guard !grid.isEmpty, x1 >= x0, y1 >= y0, x1 >= 0, y1 >= 0, x0 <= 1, y0 <= 1 else { return [] }
        var out: [Int] = []
        for cy in Self.cellCoordinate(y0)...Self.cellCoordinate(y1) {
            for cx in Self.cellCoordinate(x0)...Self.cellCoordinate(x1) {
                for i in grid[cy * Self.gridSize + cx] {
                    let n = nodes[Int(i)]
                    if n.x >= x0, n.x <= x1, n.y >= y0, n.y <= y1 { out.append(Int(i)) }
                }
            }
        }
        return out
    }

    /// What a tap at (`x`, `y`) in the unit square does (review of #54, L3).
    public enum TapTarget: Equatable, Sendable {
        /// Opens the note at this node index.
        case note(Int)
        /// Zooms to fit this region.
        case region(Region)
        case nothing
    }

    /// At the groups' level a tap inside a group zooms there (a big map's overview is too dense to aim at one note);
    /// closer in, a tap opens the note whose dot it hits (the dot's radius and a few points), else zooms into the
    /// cluster around it.
    public func tapTarget(x: Double, y: Double, pointsPerUnit: Double, detail: MapDetail) -> TapTarget {
        func region(level: Int) -> Region? {
            regions.filter { $0.level == level && !$0.isOther && hypot($0.x - x, $0.y - y) <= $0.radius }.min { $0.radius < $1.radius }
        }
        if detail.regionLevel == 1, let r = region(level: 1) { return .region(r) }
        if let i = node(near: x, y, reach: (detail.dot + 4) / max(pointsPerUnit, 1e-9)) { return .note(i) }
        if let r = region(level: detail.regionLevel) { return .region(r) }
        return .nothing
    }

    /// A node's color key: its cluster's zoomed in, its group's zoomed out (a group reads as one color); nil (gray) for
    /// a note in no cluster or in "Other".
    public func colorKey(_ i: Int, level: Int) -> Int? {
        let n = nodes[i]
        if level == 1, let g = n.group { return g }
        guard let c = n.cluster, c != MapBuilder.otherId else { return nil }
        return c
    }

    /// The region of `level` the note at `i` is in.
    public func region(of i: Int, level: Int) -> Region? {
        guard nodes.indices.contains(i), let id = level == 0 ? nodes[i].cluster : nodes[i].group else { return nil }
        return regions.first { $0.level == level && $0.id == id }
    }

    /// The level-0 clusters inside group `group`, largest first (the list's sections under a group).
    public func clusters(in group: Int?) -> [Region] {
        regions.filter { $0.level == 0 && $0.parent == group }
    }

    /// The points per unit that fit `region` in a view whose shorter side is `side` points (never below the whole map's
    /// fit, never above `maxScale`).
    public static func pointsPerUnit(toFit region: Region, side: Double, maxScale: Double) -> Double {
        min(maxScale, max(side, side * 0.8 / max(2 * region.radius, 1e-3)))
    }
}

/// What the map draws at a zoom (level of detail): pure, so the view and the tests agree.
public struct MapDetail: Equatable, Sendable {
    /// The region level whose regions and labels show: 1 (groups) zoomed out, 0 (clusters) zoomed in.
    public var regionLevel: Int
    /// Note titles show (only zoomed far in, and only for few notes on screen).
    public var titles: Bool
    /// Edges show (not at the overview: thousands of lines are a hairball and a slow frame).
    public var edges: Bool
    /// A note's dot radius in points.
    public var dot: Double

    /// `pointsPerUnit`: how many on-screen points the unit square's side spans now; `visibleNotes`: notes on screen;
    /// `hasGroups`: the map has level-1 groups (else level 0 always).
    public static func at(pointsPerUnit: Double, visibleNotes: Int, hasGroups: Bool, fitSide: Double) -> MapDetail {
        let zoom = pointsPerUnit / max(fitSide, 1)
        let level = hasGroups && zoom < 2 ? 1 : 0
        return MapDetail(regionLevel: level, titles: zoom >= 3 && visibleNotes <= titleLimit, edges: zoom >= 1.5 || visibleNotes <= edgeNoteLimit,
                         dot: min(7, max(2.5, 2.5 * zoom.squareRoot())))
    }

    /// At most this many titles are drawn in one frame.
    public static let titleLimit = 120
    /// Below this many notes on screen, edges show at any zoom.
    public static let edgeNoteLimit = 300
}
