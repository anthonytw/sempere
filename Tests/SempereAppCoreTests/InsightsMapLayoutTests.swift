import Foundation
@testable import SempereInsights
import Testing
@testable import SempereAppCore

/// The mind map's geometry (`InsightsMapLayout`, `MapDetail`; Insights PR 3): positions in the unit square, the two
/// region levels, edges once per pair, hit-testing and culling through the grid, and the level of detail by zoom, also
/// at the iPhone's graph bound.
struct InsightsMapLayoutTests {
    static func id(_ i: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", i) }

    /// Two groups of two clusters each, three notes per cluster, plus one placed note.
    static func view(basis: String = "shared") -> InsightsReader.MapView {
        var nodes: [InsightsReader.MapView.Node] = []
        let centers: [(Double, Double)] = [(-1, -1), (-0.6, -1), (1, 1), (1, 0.6)]
        for (c, (cx, cy)) in centers.enumerated() {
            for k in 0..<3 {
                nodes.append(.init(note: id(c * 10 + k), title: "N\(c)\(k)", x: cx + Double(k) * 0.05, y: cy - Double(k) * 0.05,
                                   cluster: c + 1, placed: false))
            }
        }
        nodes.append(.init(note: id(99), title: "Placed", x: 0, y: 0, cluster: 1, placed: true))
        let clusters: [InsightsReader.MapView.Cluster] = [
            .init(id: 1, parent: 10, level: 0, label: ["a"], members: 4), .init(id: 2, parent: 10, level: 0, label: ["b"], members: 3),
            .init(id: 3, parent: 11, level: 0, label: ["c"], members: 3), .init(id: 4, parent: 11, level: 0, label: ["d"], members: 3),
            .init(id: 10, parent: nil, level: 1, label: ["ab"], members: 7), .init(id: 11, parent: nil, level: 1, label: ["cd"], members: 6),
        ]
        return InsightsReader.MapView(device: "abcdef01", key: nil, basis: basis, nodes: nodes, clusters: clusters)
    }

    @Test func positionsFillTheUnitSquareAndRegionsCoverTheirMembers() throws {
        let map = InsightsMapLayout(view: Self.view(), edges: nil)
        #expect(map.nodes.count == 13)
        #expect(map.nodes.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        let xs = map.nodes.map(\.x), ys = map.nodes.map(\.y)
        #expect(abs((xs.max()! - xs.min()!) - 0.88) < 1e-9 || abs((ys.max()! - ys.min()!) - 0.88) < 1e-9, "the larger extent fills the square")
        #expect(map.regions.filter { $0.level == 1 }.count == 2)
        #expect(map.regions.filter { $0.level == 0 }.count == 4)
        #expect(map.regions.first?.level == 1, "groups first, drawn under their clusters")
        let placed = try #require(map.index[UUID(uuidString: Self.id(99))!])
        #expect(map.nodes[placed].placed)
        #expect(map.placedCount == 1)
        #expect(map.nodes[placed].group == 10, "a node's group is its cluster's parent")
        // Every region holds most of its members.
        for r in map.regions where r.level == 0 {
            let members = map.nodes.filter { $0.cluster == r.id }
            let inside = members.filter { hypot($0.x - r.x, $0.y - r.y) <= r.radius + 1e-9 }
            #expect(Double(inside.count) >= Double(members.count) * 0.75)
        }
        #expect(map.clusters(in: 10).map(\.id).sorted() == [1, 2])
        #expect(map.region(of: placed, level: 0)?.id == 1)
    }

    @Test func aLocalMapHasNoDashedNotesButSaysSo() {
        var v = Self.view(basis: "local")
        for i in v.nodes.indices { v.nodes[i].placed = true }
        let map = InsightsMapLayout(view: v, edges: nil)
        #expect(map.isLocal)
        #expect(map.placedCount == 0, "the banner says the whole map is this device's; no note is dashed")
    }

    @Test func edgesArePairsOnceBetweenNotesOnTheMap() {
        let a = UUID(uuidString: Self.id(0))!, b = UUID(uuidString: Self.id(1))!, gone = UUID()
        func edge(_ to: UUID) -> RelatedEdge { RelatedEdge(note: to, score: 1, csls: nil, keywordOverlap: 0, shared: []) }
        let map = InsightsMapLayout(view: Self.view(), edges: [a: [edge(b), edge(gone), edge(a)], b: [edge(a)]])
        #expect(map.edges.count == 1)
        #expect(map.edges[0].a < map.edges[0].b)
    }

    @Test func hitTestingAndCullingUseTheGrid() throws {
        let map = InsightsMapLayout(view: Self.view(), edges: nil)
        let placed = try #require(map.index[UUID(uuidString: Self.id(99))!])
        let n = map.nodes[placed]
        #expect(map.node(near: n.x + 0.001, n.y, reach: 0.01) == placed)
        #expect(map.node(near: n.x + 0.2, n.y + 0.2, reach: 0.01) == nil)
        #expect(map.nodes(inX: 0, 1, y: 0, 1).count == map.nodes.count)
        #expect(map.nodes(inX: n.x - 0.01, n.x + 0.01, y: n.y - 0.01, n.y + 0.01) == [placed])
        #expect(map.nodes(inX: 2, 3, y: 2, 3).isEmpty)
        #expect(InsightsMapLayout.empty.node(near: 0.5, 0.5, reach: 1) == nil)
    }

    @Test func levelOfDetailFollowsTheZoom() {
        let fit = 400.0
        let overview = MapDetail.at(pointsPerUnit: fit, visibleNotes: 1500, hasGroups: true, fitSide: fit)
        #expect(overview.regionLevel == 1)
        #expect(!overview.titles)
        #expect(!overview.edges, "no hairball at the overview of a big map")
        let small = MapDetail.at(pointsPerUnit: fit, visibleNotes: 40, hasGroups: true, fitSide: fit)
        #expect(small.edges, "a small map shows its edges at once")
        let mid = MapDetail.at(pointsPerUnit: fit * 2.5, visibleNotes: 600, hasGroups: true, fitSide: fit)
        #expect(mid.regionLevel == 0)
        #expect(mid.edges)
        #expect(!mid.titles)
        let close = MapDetail.at(pointsPerUnit: fit * 6, visibleNotes: 50, hasGroups: true, fitSide: fit)
        #expect(close.titles)
        #expect(close.dot > overview.dot)
        #expect(!MapDetail.at(pointsPerUnit: fit * 6, visibleNotes: MapDetail.titleLimit + 1, hasGroups: true, fitSide: fit).titles)
        #expect(MapDetail.at(pointsPerUnit: fit, visibleNotes: 10, hasGroups: false, fitSide: fit).regionLevel == 0)
    }

    /// The iPhone's bound (1,500 notes, `AppInsights.maxGraphNotes`): built once, then a frame's culling and a tap's
    /// hit test touch only a few grid cells.
    @Test func aBigMapStaysCheap() {
        var nodes: [InsightsReader.MapView.Node] = []
        var rng = SystemRandomNumberGenerator()
        for i in 0..<1500 {
            nodes.append(.init(note: Self.id(i), title: "", x: Double.random(in: -1.6...1.6, using: &rng), y: Double.random(in: -1.6...1.6, using: &rng),
                               cluster: i % 30, placed: false))
        }
        let clusters = (0..<30).map { InsightsReader.MapView.Cluster(id: $0, parent: nil, level: 0, label: ["t\($0)"], members: 50) }
        var edges: [UUID: [RelatedEdge]] = [:]
        for i in 0..<1500 {
            edges[UUID(uuidString: Self.id(i))!] = (1...8).map {
                RelatedEdge(note: UUID(uuidString: Self.id((i + $0 * 37) % 1500))!, score: 1, csls: nil, keywordOverlap: 0, shared: [])
            }
        }
        let start = ContinuousClock.now
        let map = InsightsMapLayout(view: .init(device: nil, key: nil, basis: "shared", nodes: nodes, clusters: clusters), edges: edges)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(map.nodes.count == 1500)
        #expect(map.edges.count <= 1500 * 8)
        let visible = map.nodes(inX: 0.4, 0.5, y: 0.4, 0.5)
        #expect(visible.count < 200, "a zoomed-in frame draws a small part")
        #expect(map.regions.count == 30)
    }
}
