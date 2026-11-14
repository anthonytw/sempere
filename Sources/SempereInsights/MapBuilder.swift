import Foundation
import Sempere

// MARK: - Steps 7 and 8: clustering, layout and placement (docs/design/1.2-note-insights.md §4, §3.8)
//
// Louvain with sorted node order, a fixed resolution and ties by the lowest id; clusters under 3 notes merge into
// "Other"; two levels kept; a label is the top 3 terms by in-cluster over out-of-cluster IDF weight. The layout is
// Fruchterman-Reingold, 300 iterations, initial positions from a hash of the note id (or the previous build's),
// clusters pulled to ring slots by id, rounded to 1e-3. Cluster ids follow the previous build by member overlap, so
// labels and positions stay put. Placement of a new note is a pure function too.

/// Deterministic numbers from ids (SHA-256, the same on every platform).
public enum HashUnit {
    /// A value in [0, 1) from `id` and `salt`.
    public static func value(_ id: UUID, _ salt: String) -> Double {
        let hex = FileDigest.sha256(Data((id.uuidString.lowercased() + "|" + salt).utf8))
        let x = UInt64(hex.prefix(16), radix: 16) ?? 0
        return Double(x >> 11) / Double(1 << 53)
    }
}

/// A weighted undirected graph over notes 0..<n (sorted by id).
public struct WeightedGraph: Sendable {
    public var n: Int
    /// adjacency: neighbour → weight (no self loops).
    public var adj: [[Int: Double]]

    public init(n: Int) { self.n = n; adj = Array(repeating: [:], count: n) }

    public mutating func add(_ i: Int, _ j: Int, _ w: Double) {
        guard i != j, w > 0 else { return }
        adj[i][j, default: 0] += w; adj[j][i, default: 0] += w
    }
}

public enum Louvain {
    public static let resolution = 1.0

    /// One level of Louvain: each node's community (relabelled 0..<k in order of each community's lowest node).
    public static func communities(_ g: WeightedGraph, resolution: Double = resolution) -> [Int] {
        let n = g.n
        var comm = Array(0..<n)
        let k = g.adj.map { $0.values.reduce(0, +) }
        let m2 = k.reduce(0, +)
        guard m2 > 0 else { return comm }
        var tot = k
        var improved = true
        var rounds = 0
        while improved && rounds < 50 {
            improved = false
            rounds += 1
            for i in 0..<n {
                let ci = comm[i]
                var links: [Int: Double] = [:]
                for (j, w) in g.adj[i] { links[comm[j], default: 0] += w }
                tot[ci] -= k[i]
                var best = ci
                var bestGain = (links[ci] ?? 0) - resolution * tot[ci] * k[i] / m2
                for c in links.keys.sorted() {
                    let gain = (links[c] ?? 0) - resolution * tot[c] * k[i] / m2
                    if gain > bestGain + 1e-12 || (abs(gain - bestGain) <= 1e-12 && c < best) { best = c; bestGain = gain }
                }
                tot[best] += k[i]
                if best != ci { comm[i] = best; improved = true }
            }
        }
        return relabel(comm)
    }

    static func relabel(_ comm: [Int]) -> [Int] {
        var map: [Int: Int] = [:]
        return comm.map { c in
            if let x = map[c] { return x }
            let x = map.count
            map[c] = x
            return x
        }
    }

    /// The graph of communities: one node per community, edge weights summed.
    public static func aggregate(_ g: WeightedGraph, _ comm: [Int]) -> WeightedGraph {
        var out = WeightedGraph(n: (comm.max() ?? -1) + 1)
        for i in 0..<g.n { for (j, w) in g.adj[i] where i < j { out.add(comm[i], comm[j], w) } }
        return out
    }
}

/// A built map: two levels of clusters and positions (the content of `InsightsMapFile`).
public struct BuiltMap: Sendable {
    public struct Cluster: Hashable, Sendable {
        public var id: Int
        public var parent: Int?
        public var level: Int
        public var label: [String]
        public var centroid: [Float]
        public var members: [UUID]
    }
    public var mean: [Float]
    public var clusters: [Cluster]
    public var positions: [UUID: (x: Double, y: Double)]
}

public enum MapBuilder {
    public static let minClusterSize = 3
    /// The id of "Other" (clusters under 3 notes).
    public static let otherId = 0
    public static let iterations = 300
    public static let neighbours = 8

    /// Builds the map of `notes` (each with a vector), warm-starting from `previous`. Deterministic: the same input
    /// gives the same clusters and positions (to 1e-3) on every platform.
    public static func build(_ notes: [RelatedInput], corpus: InsightsCorpus, previous: InsightsMapFile? = nil) -> BuiltMap {
        let notes = notes.filter { $0.vector != nil }.sorted { $0.id.uuidString < $1.id.uuidString }
        let n = notes.count
        let raw = notes.compactMap(\.vector)
        let mean = VectorMath.mean(raw) ?? []
        let vs = raw.map { VectorMath.centered($0, mean: mean) }
        // kNN graph on centered cosines.
        var g = WeightedGraph(n: n)
        for i in 0..<n {
            let near = (0..<n).filter { $0 != i }.map { ($0, VectorMath.dot(vs[i], vs[$0])) }
                .sorted { ($0.1, -$0.0) > ($1.1, -$1.0) }.prefix(neighbours)
            for (j, c) in near where c > 0 { g.add(i, j, c) }
        }
        let level0 = Louvain.communities(g)
        let level1 = Louvain.communities(Louvain.aggregate(g, level0))
        // Groups, with small ones into Other.
        var groups0: [Int: [Int]] = [:]
        for (i, c) in level0.enumerated() { groups0[c, default: []].append(i) }
        var clusters: [BuiltMap.Cluster] = []
        var other: [Int] = []
        var made0: [(members: [Int], parent: Int)] = []
        for c in groups0.keys.sorted() {
            let m = groups0[c] ?? []
            if m.count < minClusterSize { other += m } else { made0.append((m, level1[c])) }
        }
        var groups1: [Int: [Int]] = [:]
        for (members, parent) in made0 { groups1[parent, default: []] += members }
        // Ids follow the previous build by member overlap.
        let prev0 = (previous?.clusters ?? []).filter { $0.level == 0 && $0.id != otherId }
        let prev1 = (previous?.clusters ?? []).filter { $0.level == 1 }
        var nextId = max(otherId, (previous?.clusters.map(\.id).max() ?? 0)) + 1
        func ids(for sets: [[Int]], previous: [InsightsMapFile.Cluster]) -> [Int] {
            let memberSets = sets.map { Set($0.map { notes[$0].id.uuidString.lowercased() }) }
            var candidates: [(overlap: Double, set: Int, prev: Int)] = []
            for (si, s) in memberSets.enumerated() {
                for (pi, p) in previous.enumerated() {
                    let ps = Set(p.members)
                    let inter = Double(s.intersection(ps).count)
                    guard inter > 0 else { continue }
                    candidates.append((inter / Double(s.union(ps).count), si, pi))
                }
            }
            candidates.sort { ($0.overlap, -$0.set, -$0.prev) > ($1.overlap, -$1.set, -$1.prev) }
            var assigned = [Int?](repeating: nil, count: sets.count)
            var used = Set<Int>()
            for c in candidates where c.overlap >= 0.3 && assigned[c.set] == nil && !used.contains(c.prev) {
                assigned[c.set] = previous[c.prev].id; used.insert(c.prev)
            }
            return assigned.map { a in
                if let a { return a }
                defer { nextId += 1 }
                return nextId
            }
        }
        let keys1 = groups1.keys.sorted()
        let sets1 = keys1.map { groups1[$0] ?? [] }
        let ids1 = ids(for: sets1, previous: prev1)
        var parentId: [Int: Int] = [:]
        for (k, id) in zip(keys1, ids1) { parentId[k] = id }
        let sets0 = made0.map(\.members)
        let ids0 = ids(for: sets0, previous: prev0)
        func centroid(_ members: [Int]) -> [Float] { VectorMath.normalized(VectorMath.mean(members.map { vs[$0] }) ?? []) }
        let allTokens = notes.map(\.tokens)
        func label(_ members: [Int]) -> [String] {
            let inside = Set(members)
            var inW: [String: Double] = [:], outW: [String: Double] = [:]
            for i in 0..<n {
                for t in allTokens[i] where corpus.idf(t) > 0 {
                    if inside.contains(i) { inW[t, default: 0] += corpus.idf(t) } else { outW[t, default: 0] += corpus.idf(t) }
                }
            }
            let inN = Double(max(1, members.count)), outN = Double(max(1, n - members.count))
            return inW.map { t, w in (t, (w / inN) / (1 + (outW[t] ?? 0) / outN)) }
                .sorted { ($0.1, $1.0) > ($1.1, $0.0) }.prefix(3).map(\.0)
        }
        for (members, id) in zip(sets0, ids0) {
            let p = made0.first { $0.members == members }.map { parentId[$0.parent] } ?? nil
            clusters.append(.init(id: id, parent: p, level: 0, label: label(members), centroid: centroid(members),
                                  members: members.map { notes[$0].id }))
        }
        for (members, id) in zip(sets1, ids1) {
            clusters.append(.init(id: id, parent: nil, level: 1, label: label(members), centroid: centroid(members),
                                  members: members.map { notes[$0].id }))
        }
        if !other.isEmpty {
            clusters.append(.init(id: otherId, parent: nil, level: 0, label: ["other"], centroid: centroid(other),
                                  members: other.map { notes[$0].id }))
        }
        clusters.sort { ($0.level, $0.id) < ($1.level, $1.id) }
        // Layout.
        var clusterOf = [Int](repeating: otherId, count: n)
        let index = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($1.id, $0) })
        for c in clusters where c.level == 0 { for m in c.members { if let i = index[m] { clusterOf[i] = c.id } } }
        let positions = layout(ids: notes.map(\.id), graph: g, clusterOf: clusterOf, previous: previous?.positions ?? [:])
        return BuiltMap(mean: mean, clusters: clusters, positions: positions)
    }

    /// Fruchterman-Reingold over `graph` (design §4 step 8): `iterations` steps, initial positions from the previous
    /// build or a hash of the id, each cluster pulled to its ring slot (slots in cluster-id order), rounded to 1e-3.
    public static func layout(ids: [UUID], graph g: WeightedGraph, clusterOf: [Int],
                              previous: [UUID: (x: Double, y: Double)]) -> [UUID: (x: Double, y: Double)] {
        let n = ids.count
        guard n > 0 else { return [:] }
        var x = [Double](repeating: 0, count: n), y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if let p = previous[ids[i]] { x[i] = p.x; y[i] = p.y } else {
                x[i] = HashUnit.value(ids[i], "x") * 2 - 1; y[i] = HashUnit.value(ids[i], "y") * 2 - 1
            }
        }
        let slots = Array(Set(clusterOf)).sorted()
        var anchor: [Int: (Double, Double)] = [:]
        for (k, c) in slots.enumerated() {
            let a = 2 * Double.pi * Double(k) / Double(max(1, slots.count))
            anchor[c] = slots.count == 1 ? (0, 0) : (0.6 * cos(a), 0.6 * sin(a))
        }
        let area = 4.0
        let kk = sqrt(area / Double(n))
        var t = 0.1
        let cool = t / Double(iterations + 1)
        for _ in 0..<iterations {
            var dx = [Double](repeating: 0, count: n), dy = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var ddx = x[i] - x[j], ddy = y[i] - y[j]
                    var d = sqrt(ddx * ddx + ddy * ddy)
                    if d < 1e-6 { ddx = HashUnit.value(ids[i], "jx\(j)") - 0.5; ddy = HashUnit.value(ids[i], "jy\(j)") - 0.5; d = 1e-3 }
                    let f = kk * kk / d
                    dx[i] += ddx / d * f; dy[i] += ddy / d * f
                    dx[j] -= ddx / d * f; dy[j] -= ddy / d * f
                }
            }
            for i in 0..<n {
                for (j, w) in g.adj[i] where i < j {
                    let ddx = x[i] - x[j], ddy = y[i] - y[j]
                    let d = max(1e-6, sqrt(ddx * ddx + ddy * ddy))
                    let f = d * d / kk * w
                    dx[i] -= ddx / d * f; dy[i] -= ddy / d * f
                    dx[j] += ddx / d * f; dy[j] += ddy / d * f
                }
                if let (ax, ay) = anchor[clusterOf[i]] {
                    dx[i] += (ax - x[i]) * 0.5; dy[i] += (ay - y[i]) * 0.5
                }
            }
            for i in 0..<n {
                let d = max(1e-9, sqrt(dx[i] * dx[i] + dy[i] * dy[i]))
                let step = min(d, t)
                x[i] = min(1.5, max(-1.5, x[i] + dx[i] / d * step))
                y[i] = min(1.5, max(-1.5, y[i] + dy[i] / d * step))
            }
            t -= cool
        }
        var out: [UUID: (x: Double, y: Double)] = [:]
        for i in 0..<n { out[ids[i]] = ((x[i] * 1000).rounded() / 1000, (y[i] * 1000).rounded() / 1000) }
        return out
    }

    /// Where a note not in the map goes (design §3.8 "placed"): the nearest centroid per level, and the mean position
    /// of its 3 nearest neighbours in the map plus a small offset hashed from its id. Pure.
    public static func place(id: UUID, vector: [Float], map: InsightsMapFile, vectors: [UUID: [Float]])
        -> (clusters: [Int], position: (x: Double, y: Double))? {
        guard let dim = map.dim, vector.count == dim else { return nil }
        let mean = map.meanVector
        let v = VectorMath.centered(vector, mean: mean)
        var chosen: [Int] = []
        for level in 0...1 {
            let best = map.clusters.filter { $0.level == level && $0.id != otherId }.compactMap { c -> (Int, Double)? in
                guard let cv = Float16Codec.decode(c.centroid, count: dim) else { return nil }
                return (c.id, VectorMath.dot(v, cv))
            }.sorted { ($0.1, -$0.0) > ($1.1, -$1.0) }.first
            if let best { chosen.append(best.0) }
        }
        let positions = map.positions
        let near = vectors.compactMap { k, u -> (UUID, Double)? in
            guard k != id, positions[k] != nil, u.count == dim else { return nil }
            return (k, VectorMath.dot(v, VectorMath.centered(u, mean: mean)))
        }.sorted { ($0.1, $1.0.uuidString) > ($1.1, $0.0.uuidString) }.prefix(3)
        guard !near.isEmpty else { return nil }
        var px = 0.0, py = 0.0
        for (k, _) in near { if let p = positions[k] { px += p.x; py += p.y } }
        px /= Double(near.count); py /= Double(near.count)
        px += (HashUnit.value(id, "px") - 0.5) * 0.04
        py += (HashUnit.value(id, "py") - 0.5) * 0.04
        return (chosen, ((px * 1000).rounded() / 1000, (py * 1000).rounded() / 1000))
    }

    /// SHA-256 hex over the sorted `noteId:hash` lines (the map's `built.hashes`, a topic's `membersHash`).
    public static func digest(_ pairs: [(UUID, String)]) -> String {
        let lines = pairs.map { "\($0.0.uuidString.lowercased()):\($0.1)" }.sorted().joined(separator: "\n")
        return FileDigest.sha256(Data(lines.utf8))
    }
}
