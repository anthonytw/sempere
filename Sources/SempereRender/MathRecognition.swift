import Foundation
import Sempere

// MARK: - Handwritten math → LaTeX: the recogniser side (docs/attachments.md §14 G1 part 2)
//
// A recogniser reads a `MathInkImage` and proposes LaTeX. The model runs
// behind `MathRecognizing` (Core ML in `CoreMLMathRecognizer`, a fake in
// tests); everything around it is pure Swift and shared by the app and
// `sempere recognize-math`: the token vocabulary, beam search over the
// decoder's next-token scores, and the clean-up that turns a model's token
// string into a source `MathSource.check` and SwiftMath accept.

/// One reading of the ink.
public struct MathCandidate: Hashable, Sendable, Codable {
    /// LaTeX math-mode source, cleaned (`LaTeXCleanup.clean`).
    public var latex: String
    /// Mean log-probability per token of the decoder's reading (higher is
    /// more confident; 0 is certain). Nil from recognisers that give none.
    public var score: Double?

    public init(latex: String, score: Double? = nil) { self.latex = latex; self.score = score }
}

/// What a recogniser read, best first.
public struct MathRecognition: Hashable, Sendable, Codable {
    public var candidates: [MathCandidate]
    /// The model that read it (`MathModelManifest.id`), for `--json` and diagnostics.
    public var engine: String
    /// Seconds spent in the model.
    public var seconds: Double

    public init(candidates: [MathCandidate], engine: String, seconds: Double) {
        self.candidates = candidates; self.engine = engine; self.seconds = seconds
    }

    public var best: MathCandidate? { candidates.first }
}

/// Reads handwritten math. Implementations are on device only (DESIGN.md):
/// `CoreMLMathRecognizer` on Apple platforms; tests use a fake.
public protocol MathRecognizing: Sendable {
    /// The image the recogniser wants (`MathInkImage.render(strokes:spec:)`).
    var imageSpec: MathImageSpec { get }
    /// Reads `image`. Slow (a model runs): call it off the main actor.
    func recognize(_ image: MathInkImage) throws -> MathRecognition
}

extension MathRecognizing {
    /// Draws `strokes` as `imageSpec` says and reads them. Nil when no stroke is readable.
    public func recognize(strokes: [Stroke]) throws -> MathRecognition? {
        guard let image = try MathInkImage.render(strokes: strokes, spec: imageSpec) else { return nil }
        return try recognize(image)
    }
}

// MARK: - Vocabulary

/// A decoder's vocabulary, for turning token ids back into text (decoding
/// only: recognisers never encode text).
public struct MathVocabulary: Hashable, Sendable {
    /// How tokens become text.
    public enum Joining: String, Hashable, Sendable, Codable {
        /// GPT-2 byte-level BPE (pix2tex, TrOCR / Pix2Text, Nougat / UniMERNet
        /// tokenizers): each token's characters stand for bytes; `Ġ` is a space.
        case byteLevel
        /// Whole LaTeX tokens joined with spaces (CROHME models: BTTR, CoMER, TAMER).
        case words
    }

    public var tokens: [String]
    public var joining: Joining
    /// Ids never shown (padding, start, end, unknown).
    public var special: Set<Int>

    public init(tokens: [String], joining: Joining, special: Set<Int> = []) {
        self.tokens = tokens; self.joining = joining; self.special = special
    }

    /// Most tokens a vocabulary may have.
    public static let maxTokens = 262_144
    /// Longest token, UTF-8 bytes.
    public static let maxTokenBytes = 1_024

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        case malformed(String)
        public var description: String {
            switch self { case .malformed(let why): return "the model's vocabulary is not usable: \(why)" }
        }
    }

    /// Reads a Hugging Face `tokenizer.json` (its `model.vocab` map and
    /// `added_tokens`), or a plain JSON array of token strings indexed by id.
    /// The file comes with a downloaded model whose hash was checked, but it
    /// is still parsed defensively: sizes bounded, ids range-checked, every id
    /// below the count filled.
    public static func parse(_ data: Data, joining: Joining) throws -> MathVocabulary {
        guard data.count <= 64 << 20 else { throw Failure.malformed("file too large") }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch { throw Failure.malformed("not JSON") }
        var byID: [Int: String] = [:]
        var special = Set<Int>()
        func put(_ token: String, _ id: Int) throws {
            guard id >= 0, id < maxTokens else { throw Failure.malformed("token id \(id) out of range") }
            guard token.utf8.count <= maxTokenBytes else { throw Failure.malformed("token too long") }
            byID[id] = token
        }
        if let list = json as? [Any] {
            guard list.count <= maxTokens else { throw Failure.malformed("too many tokens") }
            for (i, t) in list.enumerated() {
                guard let s = t as? String else { throw Failure.malformed("token \(i) is not a string") }
                try put(s, i)
            }
        } else if let root = json as? [String: Any], let model = root["model"] as? [String: Any],
                  let vocab = model["vocab"] as? [String: Any] {
            guard vocab.count <= maxTokens else { throw Failure.malformed("too many tokens") }
            for (token, value) in vocab {
                guard let id = (value as? NSNumber)?.intValue else { throw Failure.malformed("id of \(token) is not a number") }
                try put(token, id)
            }
            for case let added as [String: Any] in root["added_tokens"] as? [Any] ?? [] {
                guard let id = (added["id"] as? NSNumber)?.intValue, let content = added["content"] as? String else { continue }
                try put(content, id)
                if (added["special"] as? NSNumber)?.boolValue == true { special.insert(id) }
            }
        } else {
            throw Failure.malformed("neither a tokenizer.json nor a list of tokens")
        }
        let count = (byID.keys.max() ?? -1) + 1
        guard count > 0, byID.count == count else { throw Failure.malformed("token ids are not 0..<\(count)") }
        return MathVocabulary(tokens: (0..<count).map { byID[$0] ?? "" }, joining: joining, special: special)
    }

    /// The text of `ids`, special and out-of-range ids left out.
    public func text(_ ids: [Int]) -> String {
        let pieces = ids.compactMap { id -> String? in
            guard id >= 0, id < tokens.count, !special.contains(id) else { return nil }
            return tokens[id]
        }
        switch joining {
        case .words:
            return pieces.joined(separator: " ")
        case .byteLevel:
            var bytes: [UInt8] = []
            for piece in pieces {
                for scalar in piece.unicodeScalars {
                    if let b = Self.byteForScalar[scalar.value] {
                        bytes.append(b)
                    } else {
                        bytes.append(contentsOf: Array(String(scalar).utf8))
                    }
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// GPT-2's byte ↔ printable-character table, reversed: printable bytes
    /// stand for themselves, the other 68 for U+0100 upwards.
    static let byteForScalar: [UInt32: UInt8] = {
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = printable
        var n = 0
        for b in 0..<256 where !printable.contains(b) {
            printable.append(b)
            scalars.append(256 + n)
            n += 1
        }
        var table: [UInt32: UInt8] = [:]
        for (b, s) in zip(printable, scalars) { table[UInt32(s)] = UInt8(b) }
        return table
    }()
}

// MARK: - Beam search

/// Beam search over an autoregressive decoder's next-token scores.
public enum MathBeamSearch {
    /// One finished or running hypothesis.
    public struct Hypothesis: Hashable, Sendable {
        /// Token ids after the start token (the end token not included).
        public var tokens: [Int]
        /// Sum of log-probabilities.
        public var logProbability: Double
        /// Mean log-probability per token (the end token counted).
        public var meanLogProbability: Double { logProbability / Double(tokens.count + 1) }
    }

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// The decoder returned scores of the wrong length or not finite.
        case badScores(Int)
        public var description: String {
            switch self { case .badScores(let n): return "the model returned \(n) scores, not one per token" }
        }
    }

    /// Log-softmax of `logits` (numerically stable).
    public static func logSoftmax(_ logits: [Float]) -> [Double] {
        let m = Double(logits.max() ?? 0)
        var sum = 0.0
        for v in logits { sum += Foundation.exp(Double(v) - m) }
        let log = Foundation.log(sum) + m
        return logits.map { Double($0) - log }
    }

    /// The `width` best readings, best first. `step` takes a prefix
    /// (`start` then the tokens so far) and returns the logits of the next
    /// token, one per vocabulary entry (`vocabularySize`). Each beam stops at
    /// `end`; the search stops once `width` beams ended or after `maxLength`
    /// tokens, so at most `width × maxLength` steps run. Without any ended
    /// beam, the ones cut at `maxLength` are returned (they may still help).
    public static func search(start: Int, end: Int, vocabularySize: Int, width: Int, maxLength: Int,
                              step: ([Int]) throws -> [Float]) throws -> [Hypothesis] {
        let width = max(1, width)
        var beams = [Hypothesis(tokens: [], logProbability: 0)]
        var finished: [Hypothesis] = []
        for _ in 0..<max(1, maxLength) {
            var candidates: [(Hypothesis, ended: Bool)] = []
            for beam in beams {
                let logits = try step([start] + beam.tokens)
                guard logits.count == vocabularySize, logits.allSatisfy(\.isFinite) else {
                    throw Failure.badScores(logits.count)
                }
                for (token, lp) in top(logSoftmax(logits), width) {
                    candidates.append((Hypothesis(tokens: token == end ? beam.tokens : beam.tokens + [token],
                                                  logProbability: beam.logProbability + lp), token == end))
                }
            }
            // The `width` best continuations of all beams: those that ended are
            // readings, the others the next beams.
            candidates.sort { $0.0.logProbability > $1.0.logProbability }
            beams = []
            for (h, ended) in candidates.prefix(width) {
                if ended { finished.append(h) } else { beams.append(h) }
            }
            guard let best = beams.first else { break }
            // Hugging Face's "heuristic" early stopping: enough readings, and the
            // best running beam already scores below the worst of them.
            if finished.count >= width,
               let worst = finished.map(\.meanLogProbability).sorted(by: >).prefix(width).last,
               best.logProbability / Double(best.tokens.count + 1) < worst {
                break
            }
        }
        let all = finished + (finished.isEmpty ? beams : [])
        return Array(all.sorted { $0.meanLogProbability > $1.meanLogProbability }.prefix(width))
    }

    /// The `k` largest entries of `scores` with their indices, largest first.
    static func top(_ scores: [Double], _ k: Int) -> [(Int, Double)] {
        var best: [(Int, Double)] = []
        for (i, s) in scores.enumerated() where best.count < k || s > best[best.count - 1].1 {
            let at = best.firstIndex { s > $0.1 } ?? best.count
            best.insert((i, s), at: at)
            if best.count > k { best.removeLast() }
        }
        return best
    }
}

// MARK: - Clean-up

/// Turns a model's output into a LaTeX source for `NoteOps.math`: the
/// recognisers write tokens separated by spaces, sometimes with delimiters
/// or display wrappers around them.
public enum LaTeXCleanup {
    /// Commands models emit that change nothing in a math item, removed.
    static let dropped: Set<String> = ["displaystyle", "textstyle", "scriptstyle", "nonumber", "notag"]

    /// `raw` without math delimiters, layout-only commands and spaces that
    /// change nothing: a space stays only between a control word and a
    /// letter (`\alpha x`). NFC; no control characters.
    public static func clean(_ raw: String) -> String {
        var s = raw.precomposedStringWithCanonicalMapping
        s = String(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        s = s.trimmingCharacters(in: .whitespaces)
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        where s.count >= open.count + close.count && s.hasPrefix(open) && s.hasSuffix(close) {
            s = String(s.dropFirst(open.count).dropLast(close.count))
            break
        }
        // Tokenise: control words, control symbols, single characters.
        var out = ""
        var previousWasControlWord = false
        var pendingSpace = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == " " { pendingSpace = true; i = s.index(after: i); continue }
            var token = String(c)
            var isControlWord = false
            if c == "\\" {
                var j = s.index(after: i)
                if j < s.endIndex, s[j].isASCII, s[j].isLetter {
                    while j < s.endIndex, s[j].isASCII, s[j].isLetter { j = s.index(after: j) }
                    isControlWord = true
                } else if j < s.endIndex {
                    j = s.index(after: j)
                }
                token = String(s[i..<j])
                i = j
            } else {
                i = s.index(after: i)
            }
            if isControlWord, dropped.contains(String(token.dropFirst())) {
                pendingSpace = true
                continue
            }
            if pendingSpace, previousWasControlWord, let first = token.first, first.isASCII, first.isLetter {
                out.append(" ")
            }
            out += token
            previousWasControlWord = isControlWord
            pendingSpace = false
        }
        return out
    }
}
