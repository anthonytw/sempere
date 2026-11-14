import Foundation
import Sempere

// MARK: - Step 6: the related-notes graph (docs/design/1.2-note-insights.md §4 step 6)
//
// Computed on each reader from the compatible vector set (design §3.8) with deterministic code, so compatible devices
// agree. Vectors are mean-centered and renormalized [M: compressed cosines]; hubs are damped by CSLS
// `s(i,j) = 2 cos(i,j) - r_i - r_j` (`r_x` the mean cosine to x's 10 nearest neighbours) [M: d17 hub]; compilations
// (over 3x the median length) weigh 0.8. Keyword overlap is an IDF-weighted Jaccard over normalized content tokens
// [M: AUC 0.80]. The score is `0.6 z(csls) + 0.4 z(kw)`; an edge is kept above a per-vault knee threshold with a
// floor, at most 8 per note, between mutual top-12 neighbours only, so an unrelated note stays unlinked [M: sourdough].
// Without vectors, keyword overlap alone.

public enum VectorMath {
    public static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var s = 0.0
        for i in 0..<min(a.count, b.count) { s += Double(a[i]) * Double(b[i]) }
        return s
    }

    public static func norm(_ a: [Float]) -> Double { sqrt(dot(a, a)) }

    public static func normalized(_ a: [Float]) -> [Float] {
        let n = norm(a)
        guard n > 0 else { return a }
        return a.map { Float(Double($0) / n) }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let d = norm(a) * norm(b)
        return d > 0 ? dot(a, b) / d : 0
    }

    /// The mean of equal-length vectors (nil for none).
    public static func mean(_ vs: [[Float]]) -> [Float]? {
        guard let first = vs.first else { return nil }
        var m = [Double](repeating: 0, count: first.count)
        for v in vs where v.count == m.count { for i in m.indices { m[i] += Double(v[i]) } }
        return m.map { Float($0 / Double(vs.count)) }
    }

    /// `v - mean`, renormalized.
    public static func centered(_ v: [Float], mean: [Float]?) -> [Float] {
        guard let mean, mean.count == v.count else { return normalized(v) }
        return normalized(zip(v, mean).map { $0 - $1 })
    }
}

/// One note as the graph sees it.
public struct RelatedInput: Hashable, Sendable {
    public var id: UUID
    /// The vector (any scale), nil when the note has none in the compatible set.
    public var vector: [Float]?
    /// Normalized content tokens (keywords, concepts and text words).
    public var tokens: Set<String>
    /// The note's length in words (compilations weigh less).
    public var words: Int

    public init(id: UUID, vector: [Float]?, tokens: Set<String>, words: Int) {
        self.id = id; self.vector = vector; self.tokens = tokens; self.words = words
    }
}

/// An edge of the graph and why it is there.
public struct RelatedEdge: Hashable, Sendable, Codable {
    public var note: UUID
    public var score: Double
    public var csls: Double?
    public var keywordOverlap: Double
    /// The top 3 shared terms by IDF, or empty ("similar wording").
    public var shared: [String]

    public var why: String { shared.isEmpty ? "similar wording" : shared.joined(separator: ", ") }
}

public enum RelatedGraph {
    public static let neighboursForHubness = 10
    public static let mutualTop = 12
    public static let maxEdges = 8
    /// The score floor under the knee (in z units).
    public static let floor = 0.5

    /// Each note's edges, best first (deterministic: ties by note id).
    public static func build(_ notes: [RelatedInput], corpus: InsightsCorpus? = nil) -> [UUID: [RelatedEdge]] {
        let notes = notes.sorted { $0.id.uuidString < $1.id.uuidString }
        let n = notes.count
        guard n >= 2 else { return [:] }
        let corpus = corpus ?? InsightsCorpus(notes.map(\.tokens))
        // Keyword overlap: IDF-weighted Jaccard.
        let weights: [[String: Double]] = notes.map { note in
            var w: [String: Double] = [:]
            for t in note.tokens { let x = corpus.idf(t); if x > 0 { w[t] = x } }
            return w
        }
        var kw = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var inter = 0.0, union = 0.0
                let (a, b) = (weights[i], weights[j])
                for (t, x) in a { if b[t] != nil { inter += x }; union += x }
                for (t, x) in b where a[t] == nil { union += x }
                let s = union > 0 ? inter / union : 0
                kw[i][j] = s; kw[j][i] = s
            }
        }
        // Vector similarity: mean-centered, CSLS.
        let withVectors = notes.allSatisfy { $0.vector != nil } && notes.count >= 3
        var csls: [[Double]]?
        if withVectors {
            let raw = notes.compactMap(\.vector)
            let mean = VectorMath.mean(raw)
            let vs = raw.map { VectorMath.centered($0, mean: mean) }
            var cos = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            for i in 0..<n { for j in (i + 1)..<n { let c = VectorMath.dot(vs[i], vs[j]); cos[i][j] = c; cos[j][i] = c } }
            let k = min(neighboursForHubness, n - 1)
            let r: [Double] = (0..<n).map { i in
                let top = (0..<n).filter { $0 != i }.map { cos[i][$0] }.sorted(by: >).prefix(k)
                return top.reduce(0, +) / Double(max(1, top.count))
            }
            let words = notes.map(\.words).sorted()
            let median = Double(words[words.count / 2])
            var s = cos
            for i in 0..<n {
                for j in 0..<n where i != j {
                    var x = 2 * cos[i][j] - r[i] - r[j]
                    if median > 0, Double(notes[i].words) > 3 * median || Double(notes[j].words) > 3 * median { x *= 0.8 }
                    s[i][j] = x
                }
            }
            csls = s
        }
        // Combined score in z units over all pairs.
        func z(_ m: [[Double]]) -> [[Double]] {
            var xs: [Double] = []
            for i in 0..<n { for j in (i + 1)..<n { xs.append(m[i][j]) } }
            let mu = xs.reduce(0, +) / Double(max(1, xs.count))
            let sd = sqrt(xs.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Double(max(1, xs.count)))
            return m.map { row in row.map { sd > 1e-12 ? ($0 - mu) / sd : 0 } }
        }
        let zk = z(kw)
        var score = zk
        if let csls {
            let zc = z(csls)
            for i in 0..<n { for j in 0..<n { score[i][j] = 0.6 * zc[i][j] + 0.4 * zk[i][j] } }
        }
        // Mutual top-12.
        let top: [Set<Int>] = (0..<n).map { i in
            Set((0..<n).filter { $0 != i }.sorted { (score[i][$0], -$0) > (score[i][$1], -$1) }.prefix(mutualTop))
        }
        // Per-vault knee: the largest drop in the sorted pair scores above the floor; edges keep at least that.
        var pairs: [Double] = []
        for i in 0..<n { for j in (i + 1)..<n where top[i].contains(j) && top[j].contains(i) { pairs.append(score[i][j]) } }
        let threshold = knee(pairs.sorted(by: >), floor: floor)
        var out: [UUID: [RelatedEdge]] = [:]
        for i in 0..<n {
            var edges: [(Int, Double)] = []
            for j in 0..<n where j != i && top[i].contains(j) && top[j].contains(i) && score[i][j] >= threshold
                && (kw[i][j] > 0 || (csls?[i][j] ?? 0) > 0) {
                edges.append((j, score[i][j]))
            }
            edges.sort { ($0.1, notes[$1.0].id.uuidString) > ($1.1, notes[$0.0].id.uuidString) }
            out[notes[i].id] = edges.prefix(maxEdges).map { j, s in
                let shared = notes[i].tokens.intersection(notes[j].tokens).filter { corpus.idf($0) > 0 }
                    .sorted { (corpus.idf($0), $1) > (corpus.idf($1), $0) }.prefix(3)
                return RelatedEdge(note: notes[j].id, score: (s * 1000).rounded() / 1000,
                                   csls: csls.map { ($0[i][j] * 1000).rounded() / 1000 },
                                   keywordOverlap: (kw[i][j] * 1000).rounded() / 1000, shared: Array(shared))
            }
        }
        return out.filter { !$0.value.isEmpty }
    }

    /// The knee of descending `scores`: the score just above the largest gap among those at or above `floor`, so the
    /// tail of weak links goes; `floor` when there is no clear gap.
    public static func knee(_ scores: [Double], floor: Double) -> Double {
        let above = scores.filter { $0 >= floor }
        guard above.count >= 3 else { return floor }
        var best = (gap: 0.0, at: floor)
        for i in 0..<(above.count - 1) {
            let gap = above[i] - above[i + 1]
            // Only a gap in the lower half: the strongest links always stay.
            if i >= above.count / 2, gap > best.gap { best = (gap, above[i]) }
        }
        return best.gap > 0.5 ? best.at : floor
    }
}
