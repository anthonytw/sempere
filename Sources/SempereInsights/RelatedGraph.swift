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
    /// Its generated keywords and concepts (a subset of `tokens`): an edge's "why" and a cluster's label prefer them
    /// to raw text words (D16: "why" read like recognizer noise from PDFs, labels like "maybe, hopefully").
    public var terms: Set<String>

    public init(id: UUID, vector: [Float]?, tokens: Set<String>, words: Int, terms: Set<String> = []) {
        self.id = id; self.vector = vector; self.tokens = tokens; self.words = words; self.terms = terms
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
    /// An edge with no shared term ("similar wording") needs both notes this long: the vector of a note of a few words
    /// is noise (D16: three-word notes linked to other unrelated three-word notes).
    public static let minWordsForWording = 25

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
        // Flat n x n matrices, three in all (review of #50, L7: six nested ones were about 1.2 GB at 5 000 notes); the
        // arithmetic and its order are the same as before, so the edges are too.
        var kw = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var inter = 0.0, union = 0.0
                let (a, b) = (weights[i], weights[j])
                for (t, x) in a { if b[t] != nil { inter += x }; union += x }
                for (t, x) in b where a[t] == nil { union += x }
                let s = union > 0 ? inter / union : 0
                kw[i * n + j] = s; kw[j * n + i] = s
            }
        }
        // Vector similarity: mean-centered, CSLS, over the notes that have a vector. A note without one (D16: a note of
        // equations only has no embedding input) takes part by keyword overlap alone; it used to turn the vectors off
        // for the whole vault.
        let hasVector = notes.map { $0.vector != nil }
        let vectorIdx = (0..<n).filter { hasVector[$0] }
        let withVectors = vectorIdx.count >= 3
        // The cosines, turned into CSLS in place (each entry needs only its own cosine and the two `r`).
        var csls: [Double]?
        if withVectors {
            let mean = VectorMath.mean(vectorIdx.compactMap { notes[$0].vector })
            var vs = [[Float]](repeating: [], count: n)
            for i in vectorIdx { if let v = notes[i].vector { vs[i] = VectorMath.centered(v, mean: mean) } }
            var m = [Double](repeating: 0, count: n * n)
            for (a, i) in vectorIdx.enumerated() {
                for j in vectorIdx[(a + 1)...] { let c = VectorMath.dot(vs[i], vs[j]); m[i * n + j] = c; m[j * n + i] = c }
            }
            vs = []
            let k = min(neighboursForHubness, vectorIdx.count - 1)
            var r = [Double](repeating: 0, count: n)
            for i in vectorIdx {
                let top = vectorIdx.filter { $0 != i }.map { m[i * n + $0] }.sorted(by: >).prefix(k)
                r[i] = top.reduce(0, +) / Double(max(1, top.count))
            }
            let words = vectorIdx.map { notes[$0].words }.sorted()
            let median = Double(words[words.count / 2])
            for i in vectorIdx {
                for j in vectorIdx where i != j {
                    var x = 2 * m[i * n + j] - r[i] - r[j]
                    if median > 0, Double(notes[i].words) > 3 * median || Double(notes[j].words) > 3 * median { x *= 0.8 }
                    m[i * n + j] = x
                }
            }
            csls = m
        }
        // Combined score in z units over all pairs (the vector part over the pairs that have one).
        func zParams(_ m: [Double], pairs: (Int, Int) -> Bool) -> (mu: Double, sd: Double) {
            var sum = 0.0, count = 0
            for i in 0..<n { for j in (i + 1)..<n where pairs(i, j) { sum += m[i * n + j]; count += 1 } }
            let mu = sum / Double(max(1, count))
            var sq = 0.0
            for i in 0..<n { for j in (i + 1)..<n where pairs(i, j) { let d = m[i * n + j] - mu; sq += d * d } }
            return (mu, sqrt(sq / Double(max(1, count))))
        }
        func z(_ x: Double, _ p: (mu: Double, sd: Double)) -> Double { p.sd > 1e-12 ? (x - p.mu) / p.sd : 0 }
        let pk = zParams(kw) { _, _ in true }
        var score = kw.map { z($0, pk) }
        if let csls {
            let pc = zParams(csls) { hasVector[$0] && hasVector[$1] }
            for i in 0..<n where hasVector[i] {
                for j in 0..<n where hasVector[j] { score[i * n + j] = 0.6 * z(csls[i * n + j], pc) + 0.4 * z(kw[i * n + j], pk) }
            }
        }
        // Mutual top-12.
        let top: [Set<Int>] = (0..<n).map { i in
            Set((0..<n).filter { $0 != i }.sorted { (score[i * n + $0], -$0) > (score[i * n + $1], -$1) }.prefix(mutualTop))
        }
        // Per-vault knee: the largest drop in the sorted pair scores above the floor; edges keep at least that.
        var pairs: [Double] = []
        for i in 0..<n { for j in (i + 1)..<n where top[i].contains(j) && top[j].contains(i) { pairs.append(score[i * n + j]) } }
        let threshold = knee(pairs.sorted(by: >), floor: floor)
        var out: [UUID: [RelatedEdge]] = [:]
        for i in 0..<n {
            var edges: [(Int, Double)] = []
            for j in 0..<n where j != i && top[i].contains(j) && top[j].contains(i) && score[i * n + j] >= threshold
                && hasReason(keywordOverlap: kw[i * n + j], csls: csls?[i * n + j], words: min(notes[i].words, notes[j].words)) {
                edges.append((j, score[i * n + j]))
            }
            edges.sort { ($0.1, notes[$1.0].id.uuidString) > ($1.1, notes[$0.0].id.uuidString) }
            out[notes[i].id] = edges.prefix(maxEdges).map { j, s in
                // Shared generated terms first, then shared text words, each by IDF.
                let bothTerms = notes[i].terms.intersection(notes[j].terms)
                let shared = notes[i].tokens.intersection(notes[j].tokens).filter { corpus.idf($0) > 0 }
                    .sorted { (bothTerms.contains($0) ? 1 : 0, corpus.idf($0), $1) > (bothTerms.contains($1) ? 1 : 0, corpus.idf($1), $0) }
                    .prefix(3)
                return RelatedEdge(note: notes[j].id, score: (s * 1000).rounded() / 1000,
                                   csls: hasVector[i] && hasVector[j] ? csls.map { ($0[i * n + j] * 1000).rounded() / 1000 } : nil,
                                   keywordOverlap: (kw[i * n + j] * 1000).rounded() / 1000, shared: Array(shared))
            }
        }
        return out.filter { !$0.value.isEmpty }
    }

    /// An edge needs a reason: a shared term, or similar wording (a positive CSLS) between notes of at least
    /// `minWordsForWording` words (`words`: the shorter one's).
    public static func hasReason(keywordOverlap: Double, csls: Double?, words: Int) -> Bool {
        keywordOverlap > 0 || ((csls ?? 0) > 0 && words >= minWordsForWording)
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
