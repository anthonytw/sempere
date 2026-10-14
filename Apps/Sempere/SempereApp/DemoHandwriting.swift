#if DEBUG
import Foundation
import Sempere

// Synthetic handwriting for the App Store screenshots (`docs/appstore/screenshots.md`).
// Nothing here is a real note: words are laid out letter by letter from
// parametric curves (humps, loops, ascenders), joined into one stroke per word
// like cursive, and smoothed with a Catmull-Rom spline. The same seed always
// gives the same strokes. Pure Foundation + Sempere, so it also builds and
// runs on Linux (the app's logic tests are typechecked there, CLAUDE.md).

/// SplitMix64: a small seeded generator, so a demo vault is reproducible.
struct DemoRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in `range`, mapped here rather than by
    /// `Double.random(in:using:)`, whose mapping the standard library may
    /// change: the demo ink must not move with an Xcode update.
    mutating func value(_ range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * 0x1p-53
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    /// A UUID drawn from the generator (version and variant bits set).
    mutating func uuid() -> UUID {
        var bytes = (0..<16).map { _ in UInt8(truncatingIfNeeded: next()) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// What the pen looks like: ink, nib width and letter size.
struct DemoPen: Sendable {
    var tool: InkTool = .pen
    var color = Color(r: 0x1E, g: 0x2A, b: 0x44)
    /// Drawn width in points (format `w`, `NibSize` converts for PencilKit).
    var width = 1.7
    /// Height of a lowercase letter without ascender, points.
    var xHeight = 8.8
    /// Average letter width, points.
    var letterWidth = 8.6
    /// Horizontal shift per unit of height: the lean of the writing.
    var slant = 0.18

    static let ink = DemoPen()
    static let blue = DemoPen(color: Color(r: 0x2B, g: 0x58, b: 0xB0))
    static let red = DemoPen(color: Color(r: 0xC2, g: 0x3B, b: 0x3B))
    static let green = DemoPen(color: Color(r: 0x2E, g: 0x7D, b: 0x4F))
    /// A broad yellow highlighter.
    static let highlighter = DemoPen(tool: .marker, color: Color(r: 0xFF, g: 0xD8, b: 0x3D), width: 11)

    /// This pen with letters `factor` times as large (and the nib scaled less).
    func scaled(_ factor: Double) -> DemoPen {
        var p = self
        p.xHeight *= factor; p.letterWidth *= factor; p.width *= 1 + (factor - 1) * 0.5
        return p
    }
}

/// A page of strokes being written. Coordinates are page points, y down.
struct DemoSheet {
    private(set) var strokes: [Stroke] = []
    private var rng: DemoRandom

    init(seed: UInt64) { rng = DemoRandom(seed: seed) }

    // MARK: Words and lines

    /// How a letter is drawn: waypoints in (u, v), u across the letter's width
    /// (0…1) and v up in x-heights (0 on the baseline).
    private enum Shape {
        case round, hump, valley, tall, cross, descender, dotted, capital, mark

        var points: [(Double, Double)] {
            switch self {
            case .round:
                return [(0.95, 0.6), (0.6, 1.0), (0.15, 0.8), (0.05, 0.4), (0.35, 0.02), (0.8, 0.25), (1.0, 0.7), (1.05, 0.05)]
            case .hump:
                return [(0.0, 0.1), (0.08, 0.95), (0.35, 1.02), (0.65, 0.8), (0.72, 0.4), (0.8, 0.04), (1.0, 0.08)]
            case .valley:
                return [(0.0, 0.95), (0.12, 0.3), (0.4, 0.0), (0.62, 0.35), (0.7, 1.0), (0.85, 0.35), (1.0, 0.05)]
            case .tall:
                return [(0.05, 0.1), (0.3, 1.1), (0.5, 1.95), (0.68, 1.9), (0.6, 1.2), (0.5, 0.4), (0.8, 0.02), (1.0, 0.08)]
            case .cross:
                return [(0.05, 0.1), (0.3, 1.0), (0.5, 1.7), (0.55, 0.9), (0.5, 0.2), (0.8, 0.02), (1.0, 0.08)]
            case .descender:
                return [(0.9, 0.95), (0.5, 1.02), (0.12, 0.65), (0.45, 0.1), (0.9, 0.9), (0.8, 0.0), (0.65, -0.7), (0.3, -0.95), (0.12, -0.5), (0.6, 0.02)]
            case .dotted:
                return [(0.0, 0.1), (0.2, 0.95), (0.35, 0.5), (0.45, 0.04), (0.8, 0.1)]
            case .capital:
                return [(0.0, 0.05), (0.3, 1.2), (0.5, 1.95), (0.7, 1.2), (0.95, 0.05), (0.7, 0.5), (0.3, 0.5), (0.1, 0.4), (1.1, 0.1)]
            case .mark:
                return [(0.2, 0.0), (0.5, 0.45), (0.8, 0.0)]
            }
        }

        init(_ c: Character) {
            if c.isUppercase { self = .capital; return }
            switch c {
            case "n", "m", "h", "r", "p": self = c == "p" ? .descender : .hump
            case "u", "v", "w", "y": self = c == "y" ? .descender : .valley
            case "l", "b", "d", "k", "f": self = .tall
            case "t": self = .cross
            case "g", "j", "q": self = .descender
            case "i": self = .dotted
            case ".", ",", "-", ":", "'", "!", "?", "(", ")": self = .mark
            default: self = .round
            }
        }

        /// Width of the letter relative to the pen's `letterWidth`.
        func width(of c: Character) -> Double {
            switch c {
            case "m", "w": return 1.7
            case "i", "l", "t", "r", "f", "j", ".", ",", ":", "'", "!", "(", ")", "-": return 0.55
            case "n", "h", "u", "v", "y", "b", "p": return 1.05
            default: return 1.0
            }
        }
    }

    /// The width `text` takes with `pen` (words joined by spaces).
    ///
    /// Three words are drawn rather than spelled: `->` is an arrow, `+` a
    /// plus sign and `*` a bullet dot.
    func width(of text: String, pen: DemoPen) -> Double {
        let space = pen.letterWidth * 0.8
        return text.split(separator: " ", omittingEmptySubsequences: true).enumerated().reduce(0) { total, item in
            let word = item.element
            let w: Double
            switch word {
            case "->": w = pen.letterWidth * 5
            case "+": w = pen.letterWidth * 1.4
            case "*": w = pen.letterWidth * 0.9
            default: w = word.reduce(0) { $0 + pen.letterWidth * Shape($1).width(of: $1) }
            }
            return total + w + (item.offset > 0 ? space : 0)
        }
    }

    /// Writes `text` centred on `cx`.
    mutating func writeCentered(_ text: String, cx: Double, baseline: Double, pen: DemoPen = .ink) {
        write(text, x: cx - width(of: text, pen: pen) / 2, baseline: baseline, pen: pen)
    }

    /// Writes `text` starting at (`x`, `baseline`). `maxWidth` squeezes it to
    /// fit. Returns the x where the writing ended.
    @discardableResult
    mutating func write(_ text: String, x: Double, baseline: Double, pen: DemoPen = .ink,
                        maxWidth: Double? = nil) -> Double {
        var pen = pen
        let natural = width(of: text, pen: pen)
        if let maxWidth, natural > maxWidth { pen = pen.scaled(maxWidth / natural) }
        var cursor = x
        // A slow drift of the baseline over the line, like a hand that is not on rails.
        let drift = rng.value(-1.6...1.6), phase = rng.value(0...6.28)
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let wordBaseline = { (px: Double) -> Double in
                baseline + drift * (px - x) / 300 + 0.7 * sin(px / 55 + phase)
            }
            let y = wordBaseline(cursor)
            switch word {
            case "->":
                arrow(from: (cursor, y - pen.xHeight * 0.45), to: (cursor + pen.letterWidth * 5, y - pen.xHeight * 0.45), pen: pen)
                cursor += pen.letterWidth * 5
            case "+":
                let w = pen.letterWidth * 1.4, mid = y - pen.xHeight * 0.5
                line(from: (cursor + w * 0.15, mid), to: (cursor + w * 0.85, mid), pen: pen)
                line(from: (cursor + w * 0.5, mid - w * 0.35), to: (cursor + w * 0.5, mid + w * 0.35), pen: pen)
                cursor += w
            case "*":
                bullet(x: cursor + pen.letterWidth * 0.4, y: y - pen.xHeight * 0.4, pen: pen)
                cursor += pen.letterWidth * 0.9
            default:
                cursor = writeWord(Array(word), x: cursor, baseline: wordBaseline, pen: pen)
            }
            cursor += pen.letterWidth * 0.8
        }
        return cursor - pen.letterWidth * 0.8
    }

    private mutating func writeWord(_ letters: [Character], x: Double, baseline: (Double) -> Double,
                                    pen: DemoPen) -> Double {
        var waypoints: [(Double, Double)] = []
        var extras: [[(Double, Double)]] = []   // i dots, t bars: separate small strokes
        var cursor = x
        for c in letters {
            let shape = Shape(c)
            let w = pen.letterWidth * shape.width(of: c) * rng.value(0.92...1.1)
            let h = pen.xHeight * rng.value(0.92...1.08)
            let steps: [(Double, Double)]
            if c == "m" || c == "w" {
                // Two humps (or valleys) side by side.
                let one = shape.points
                steps = one.map { ($0.0 * 0.5, $0.1) } + one.map { ($0.0 * 0.5 + 0.5, $0.1) }
            } else {
                steps = shape.points
            }
            for (u, v) in steps {
                let px = cursor + u * w + v * h * pen.slant + rngJitter(0.035) * w
                let py = baseline(cursor + u * w) - (v + rngJitter(0.04)) * h
                waypoints.append((px, py))
            }
            if shape == .dotted, c == "i" {
                let dx = cursor + 0.25 * w + 1.55 * h * pen.slant, dy = baseline(cursor) - 1.55 * h
                extras.append([(dx, dy), (dx + 0.6, dy - 0.5)])
            }
            if shape == .cross {
                let y = baseline(cursor) - 1.05 * h
                let cx = cursor + 0.5 * w + 1.05 * h * pen.slant
                extras.append([(cx - 0.5 * w, y + 0.3), (cx + 0.2 * w, y - 0.5), (cx + 0.8 * w, y - 0.2)])
            }
            cursor += w
        }
        addCurve(waypoints, pen: pen)
        for extra in extras { addCurve(extra, pen: pen, spacing: 1.0) }
        return cursor
    }

    private mutating func rngJitter(_ amount: Double) -> Double { rng.value(-amount...amount) }

    // MARK: Shapes

    /// A smooth stroke through `waypoints` (page points).
    mutating func addCurve(_ waypoints: [(Double, Double)], pen: DemoPen, spacing: Double = 2.0) {
        let pts = DemoSheet.smooth(waypoints, spacing: spacing)
        guard pts.count >= 2 else { return }
        // Pressure: light at both ends, a gentle swell and a little noise in between.
        let count = pts.count
        let seed = rng.value(0...6.28)
        var t = 0.0
        var points: [StrokePoint] = []
        points.reserveCapacity(count)
        for (i, p) in pts.enumerated() {
            let s = Double(i) / Double(count - 1)
            let ends = min(1, Double(i) / 3, Double(count - 1 - i) / 4)
            let pressure = (0.62 + 0.28 * sin(s * 3.1 + seed)) * (0.55 + 0.45 * ends)
            let width = pen.width * (0.7 + 0.6 * pressure)
            if i > 0 { t += hypot(p.0 - pts[i - 1].0, p.1 - pts[i - 1].1) / 160 }
            points.append(StrokePoint(x: InkJSON.round3(p.0), y: InkJSON.round3(p.1), t: InkJSON.round3(t),
                                      w: InkJSON.round3(width), h: InkJSON.round3(width), o: 1,
                                      f: InkJSON.round3(pressure), az: 0.8, al: 1.0))
        }
        strokes.append(Stroke(id: rng.uuid(), ink: Ink(tool: pen.tool, color: pen.color, width: pen.width), points: points))
    }

    /// A straight segment, slightly alive.
    mutating func line(from a: (Double, Double), to b: (Double, Double), pen: DemoPen = .ink) {
        let n = max(Int(hypot(b.0 - a.0, b.1 - a.1) / 14), 1)
        let way = (0...n).map { i -> (Double, Double) in
            let f = Double(i) / Double(n)
            return (a.0 + (b.0 - a.0) * f + rngJitter(0.5), a.1 + (b.1 - a.1) * f + rngJitter(0.5))
        }
        addCurve(way, pen: pen)
    }

    /// An arrow from `a` to `b` with a two-stroke head, as one stroke.
    mutating func arrow(from a: (Double, Double), to b: (Double, Double), pen: DemoPen = .ink) {
        line(from: a, to: b, pen: pen)
        let angle = atan2(b.1 - a.1, b.0 - a.0), head = 9.0
        let left = (b.0 - head * cos(angle - 0.45), b.1 - head * sin(angle - 0.45))
        let right = (b.0 - head * cos(angle + 0.45), b.1 - head * sin(angle + 0.45))
        addCurve([left, b, right], pen: pen, spacing: 1.5)
    }

    /// An ellipse drawn the way a hand does it: a little more than one turn.
    mutating func ellipse(cx: Double, cy: Double, rx: Double, ry: Double, pen: DemoPen = .ink, tilt: Double = 0) {
        let n = 14
        var way: [(Double, Double)] = []
        let start = rngJitter(0.4) - 1.2
        for i in 0...n {
            let a = start + 2 * Double.pi * 1.08 * Double(i) / Double(n)
            let grow = 1 + 0.04 * Double(i) / Double(n)   // the end overshoots the start
            let ex = rx * grow * cos(a) + rngJitter(0.6), ey = ry * grow * sin(a) + rngJitter(0.6)
            way.append((cx + ex * cos(tilt) - ey * sin(tilt), cy + ex * sin(tilt) + ey * cos(tilt)))
        }
        addCurve(way, pen: pen)
    }

    /// A rounded box in one stroke whose ends overlap a little.
    mutating func box(x: Double, y: Double, width: Double, height: Double, pen: DemoPen = .ink) {
        let r = min(8, width / 4, height / 4)
        let way: [(Double, Double)] = [
            (x + r, y), (x + width / 2, y + rngJitter(0.8)), (x + width - r, y), (x + width, y + r),
            (x + width + rngJitter(0.8), y + height / 2), (x + width, y + height - r), (x + width - r, y + height),
            (x + width / 2, y + height + rngJitter(0.8)), (x + r, y + height), (x, y + height - r),
            (x + rngJitter(0.8), y + height / 2), (x, y + r), (x + r, y - 1), (x + r * 2.5, y + 0.5),
        ]
        addCurve(way, pen: pen)
    }

    /// A wavy rule between `x0` and `x1`.
    mutating func underline(x0: Double, x1: Double, y: Double, pen: DemoPen = .ink, double: Bool = false) {
        let n = max(Int((x1 - x0) / 40), 2)
        func rule(_ dy: Double) -> [(Double, Double)] {
            (0...n).map { i in
                let f = Double(i) / Double(n)
                return (x0 + (x1 - x0) * f, y + dy + 1.4 * sin(f * 5) + (rng.peek(f) - 0.5))
            }
        }
        addCurve(rule(0), pen: pen)
        if double { addCurve(rule(4), pen: pen) }
    }

    /// A broad highlighter band behind writing.
    mutating func highlight(x0: Double, x1: Double, y: Double) {
        addCurve([(x0, y), ((x0 + x1) / 2, y + 0.8), (x1, y - 0.4)], pen: .highlighter, spacing: 4)
    }

    /// A filled-looking dot.
    mutating func bullet(x: Double, y: Double, pen: DemoPen = .ink) {
        addCurve([(x - 1.4, y), (x, y - 1.6), (x + 1.4, y), (x, y + 1.6), (x - 1.2, y - 0.4)], pen: pen, spacing: 0.8)
    }

    /// A function graph through `waypoints`.
    mutating func graph(_ waypoints: [(Double, Double)], pen: DemoPen = .blue) {
        addCurve(waypoints, pen: pen, spacing: 2.5)
    }

    /// A five-pointed star outline.
    mutating func star(cx: Double, cy: Double, radius: Double, pen: DemoPen = .red) {
        var way: [(Double, Double)] = []
        for k in 0...5 {
            let a = -Double.pi / 2 + Double(k * 2 % 5) * 2 * Double.pi / 5
            way.append((cx + radius * cos(a), cy + radius * sin(a)))
        }
        // Sharp corners: add the corners twice so the spline does not round them away.
        addCurve(way.flatMap { [$0, ($0.0 + 0.01, $0.1)] }, pen: pen, spacing: 1.5)
    }

    /// A padlock: body, shackle.
    mutating func lock(x: Double, y: Double, size: Double = 16, pen: DemoPen = .ink) {
        box(x: x, y: y + size * 0.45, width: size, height: size * 0.6, pen: pen)
        addCurve([(x + size * 0.2, y + size * 0.45), (x + size * 0.2, y + size * 0.1), (x + size * 0.5, y - size * 0.12),
                  (x + size * 0.8, y + size * 0.1), (x + size * 0.8, y + size * 0.45)], pen: pen, spacing: 1.5)
    }

    // MARK: Smoothing

    /// Catmull-Rom spline through `way`, sampled about every `spacing` points
    /// of path length (and at least a few times per segment).
    static func smooth(_ way: [(Double, Double)], spacing: Double) -> [(Double, Double)] {
        guard way.count >= 2 else { return way }
        var out: [(Double, Double)] = []
        let p = [way[0]] + way + [way[way.count - 1]]
        for i in 1..<(p.count - 2) {
            let (p0, p1, p2, p3) = (p[i - 1], p[i], p[i + 1], p[i + 2])
            let length = hypot(p2.0 - p1.0, p2.1 - p1.1)
            let n = max(Int((length / spacing).rounded(.up)), 2)
            for k in 0..<n {
                let t = Double(k) / Double(n), t2 = t * t, t3 = t2 * t
                func c(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append((c(p0.0, p1.0, p2.0, p3.0), c(p0.1, p1.1, p2.1, p3.1)))
            }
        }
        out.append(way[way.count - 1])
        return out
    }
}

private extension DemoRandom {
    /// A repeatable pseudo-random value in 0…1 that depends only on `f`
    /// (so a rule's wobble does not shift when other strokes are added).
    func peek(_ f: Double) -> Double {
        var copy = DemoRandom(seed: UInt64(truncatingIfNeeded: Int((f * 1000).rounded())) &+ 17)
        return copy.value(0...1)
    }
}
#endif
