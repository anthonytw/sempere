import Foundation

/// Seeded synthetic handwriting: rows of small word-like strokes, for fixtures, stress tests and
/// benchmarks (`sempere pages scribble`, the app's dense-page tests). The same seed and options give
/// the same geometry; stroke ids are fresh every time, so running it twice on one note never
/// reuses an id (format.md §5.2).
///
/// Each stroke is one glyph-sized loop (a few pen turns, 8 to 14 points wide) written left to right
/// along rows `rowHeight` apart between the page margins, like a dense page of notes: 20 000 strokes
/// on a 612-point page fill about 455 rows. Points carry time offsets, pressure, azimuth and altitude
/// as a pen would record them.
public struct SyntheticInk: Sendable {
    public struct Options: Sendable, Equatable {
        /// Control points per stroke (at least 2).
        public var pointsPerStroke: Int
        /// The page width the rows wrap at.
        public var pageWidth: Double
        /// Left and right margin.
        public var margin: Double
        /// Distance between rows.
        public var rowHeight: Double
        /// The first row's baseline.
        public var top: Double
        public var ink: Ink

        public init(pointsPerStroke: Int = 24, pageWidth: Double = 612, margin: Double = 36, rowHeight: Double = 24,
                    top: Double = 48, ink: Ink = Ink(tool: .pen, color: .black, width: 2)) {
            self.pointsPerStroke = pointsPerStroke
            self.pageWidth = pageWidth
            self.margin = margin
            self.rowHeight = rowHeight
            self.top = top
            self.ink = ink
        }
    }

    /// A recording the strokes were written during (format.md §5.6 `rec`): stroke `i` of `n` is
    /// linked at `start + (duration - start) * i / n` seconds, so the ink spreads over the recording.
    public struct Recording: Sendable, Equatable {
        public var id: UUID
        public var duration: Double
        public var start: Double
        public init(id: UUID, duration: Double, start: Double = 0) {
            self.id = id; self.duration = duration; self.start = start
        }
    }

    public private(set) var options: Options
    private var rng: SplitMix
    /// Where the next stroke goes.
    private var x: Double
    private var row = 0

    public init(seed: UInt64, options: Options = Options()) {
        self.options = options
        rng = SplitMix(state: seed)
        x = options.margin
    }

    /// The baseline of the row the next stroke goes on.
    public var nextBaseline: Double { options.top + Double(row) * options.rowHeight }

    /// The next `count` strokes, continuing where the last call stopped.
    public mutating func strokes(_ count: Int, recording: Recording? = nil) -> [Stroke] {
        var out: [Stroke] = []
        out.reserveCapacity(max(count, 0))
        for i in 0..<max(count, 0) {
            let at = recording.map { r -> RecordingLink in
                let span = max(r.duration - r.start, 0)
                return RecordingLink(id: r.id, at: InkJSON.round3(r.start + span * Double(i) / Double(max(count, 1))))
            }
            out.append(next(rec: at))
        }
        return out
    }

    /// One glyph at the pen position, then the pen moves on (a space now and then, a new row at the margin).
    private mutating func next(rec: RecordingLink?) -> Stroke {
        let o = options
        let width = 8 + Double(rng.next() % 600) / 100          // 8–14 pt
        if x + width > o.pageWidth - o.margin {
            x = o.margin
            row += 1
        }
        let base = nextBaseline
        let height = 7 + Double(rng.next() % 500) / 100          // 7–12 pt
        let turns = 1 + Double(rng.next() % 300) / 100           // 1–4 loops
        let phase = Double(rng.next() % 628) / 100
        let n = max(o.pointsPerStroke, 2)
        var points: [StrokePoint] = []
        points.reserveCapacity(n)
        for k in 0..<n {
            let u = Double(k) / Double(n - 1)
            let angle = phase + u * turns * 2 * .pi
            let px = x + u * width + 2.5 * cos(angle)
            let py = base - height / 2 - height / 2 * sin(angle)
            let force = 0.3 + 0.4 * sin(u * .pi)
            points.append(StrokePoint(x: InkJSON.round3(px), y: InkJSON.round3(py), t: InkJSON.round3(Double(k) * 0.008),
                                      w: o.ink.width + 0.5, h: o.ink.width + 0.5, o: 1, f: InkJSON.round3(force),
                                      az: 0.4, al: 1.1))
        }
        x += width + 2
        if rng.next() % 5 == 0 { x += 6 }                        // a word ends
        return Stroke(ink: o.ink, points: points, rec: rec)
    }

    /// `addStroke` ops for `count` strokes on `page`, grouped `perRevision` to a delta (the last group
    /// may be shorter): one delta per group, as a writer that saves every few strokes would leave them.
    public mutating func deltas(_ count: Int, page: UUID, perRevision: Int, recording: Recording? = nil) -> [[Op]] {
        let all = strokes(count, recording: recording).map { Op.addStroke(page: page, stroke: $0) }
        let size = max(perRevision, 1)
        return stride(from: 0, to: all.count, by: size).map { Array(all[$0..<min($0 + size, all.count)]) }
    }

    /// SplitMix64: small, fast and the same on every platform.
    struct SplitMix: Sendable {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
