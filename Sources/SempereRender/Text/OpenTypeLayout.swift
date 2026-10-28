import Foundation

/// The subset of OpenType layout the CLI's shaper uses (docs/attachments.md
/// §6): GSUB single (1) and ligature (4) substitution, GPOS mark-to-base (4),
/// mark-to-ligature (5) and mark-to-mark (6), each also inside extension
/// lookups (GSUB 7, GPOS 9); GDEF glyph classes for lookup flags.
/// Everything is bounds-checked; lookups that are not understood are skipped.
struct OpenTypeLayout: Sendable {
    let b: FontBytes
    let gsub: Int?
    let gpos: Int?
    /// GDEF glyph class definition table offset (1 base, 2 ligature, 3 mark, 4 component).
    let glyphClasses: Int?
    /// GDEF mark attachment classes.
    let markClasses: Int?

    init(_ font: OpenTypeFont) {
        b = font.bytes
        gsub = font.tables["GSUB"]?.lowerBound
        gpos = font.tables["GPOS"]?.lowerBound
        var gc: Int?, mc: Int?
        if let gdef = font.tables["GDEF"]?.lowerBound {
            if let o = try? b.u16(gdef + 4), o != 0 { gc = gdef + o }
            if let o = try? b.u16(gdef + 10), o != 0 { mc = gdef + o }
        }
        glyphClasses = gc
        markClasses = mc
    }

    func glyphClass(_ g: Int) -> Int { glyphClasses.map { classDef($0, g) } ?? 0 }

    // MARK: Common tables

    /// Coverage index of `g`, or nil.
    func coverage(_ o: Int, _ g: Int) -> Int? {
        guard let format = try? b.u16(o) else { return nil }
        if format == 1 {
            guard let n = try? b.u16(o + 2) else { return nil }
            var lo = 0, hi = n - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                guard let v = try? b.u16(o + 4 + 2 * mid) else { return nil }
                if v == g { return mid } else if v < g { lo = mid + 1 } else { hi = mid - 1 }
            }
        } else if format == 2 {
            guard let n = try? b.u16(o + 2) else { return nil }
            var lo = 0, hi = n - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = o + 4 + 6 * mid
                guard let s = try? b.u16(r), let e = try? b.u16(r + 2), let i = try? b.u16(r + 4) else { return nil }
                if g < s { hi = mid - 1 } else if g > e { lo = mid + 1 } else { return i + g - s }
            }
        }
        return nil
    }

    /// Class of `g` in a ClassDef table (0 when absent).
    func classDef(_ o: Int, _ g: Int) -> Int {
        guard let format = try? b.u16(o) else { return 0 }
        if format == 1 {
            guard let start = try? b.u16(o + 2), let n = try? b.u16(o + 4), g >= start, g < start + n else { return 0 }
            return (try? b.u16(o + 6 + 2 * (g - start))) ?? 0
        }
        if format == 2, let n = try? b.u16(o + 2) {
            var lo = 0, hi = n - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = o + 4 + 6 * mid
                guard let s = try? b.u16(r), let e = try? b.u16(r + 2) else { return 0 }
                if g < s { hi = mid - 1 } else if g > e { lo = mid + 1 } else { return (try? b.u16(r + 4)) ?? 0 }
            }
        }
        return 0
    }

    /// Lookup indices of `features` for `script` (falling back to `DFLT`,
    /// then `latn`), default language system, in lookup-list order.
    func lookups(_ table: Int?, script: String, features: Set<String>) -> [(index: Int, feature: String)] {
        guard let t = table, let scriptList = try? b.u16(t + 4), let featureList = try? b.u16(t + 6) else { return [] }
        let sl = t + scriptList, fl = t + featureList
        guard let count = try? b.u16(sl) else { return [] }
        var langSys: Int?
        for wanted in [script, "DFLT", "latn"] where langSys == nil {
            for i in 0..<min(count, 256) {
                guard let tag = try? b.tag(sl + 2 + 6 * i), tag == wanted,
                      let so = try? b.u16(sl + 2 + 6 * i + 4), let d = try? b.u16(sl + so), d != 0 else { continue }
                langSys = sl + so + d
                break
            }
        }
        guard let ls = langSys, let n = try? b.u16(ls + 4) else { return [] }
        var indices: [Int] = []
        if let req = try? b.u16(ls + 2), req != 0xFFFF { indices.append(req) }
        for i in 0..<min(n, 512) { if let f = try? b.u16(ls + 6 + 2 * i) { indices.append(f) } }
        var out: [(Int, String)] = []
        guard let fcount = try? b.u16(fl) else { return [] }
        for f in indices where f < fcount {
            guard let tag = try? b.tag(fl + 2 + 6 * f), features.contains(tag),
                  let fo = try? b.u16(fl + 2 + 6 * f + 4), let ln = try? b.u16(fl + fo + 2) else { continue }
            for j in 0..<min(ln, 512) { if let l = try? b.u16(fl + fo + 4 + 2 * j) { out.append((l, tag)) } }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// A lookup's type, flag, mark filtering set and subtable offsets (extension subtables unwrapped).
    func lookup(_ table: Int, _ index: Int) -> (type: Int, flag: Int, filter: Int?, subtables: [Int])? {
        guard let ll = try? b.u16(table + 8), let n = try? b.u16(table + ll), index < n,
              let lo = try? b.u16(table + ll + 2 + 2 * index) else { return nil }
        let l = table + ll + lo
        guard var type = try? b.u16(l), let flag = try? b.u16(l + 2), let count = try? b.u16(l + 4) else { return nil }
        var subs: [Int] = []
        let isGSUB = table == gsub
        for i in 0..<min(count, 256) {
            guard let so = try? b.u16(l + 6 + 2 * i) else { continue }
            var s = l + so
            if (isGSUB && type == 7) || (!isGSUB && type == 9) {
                guard let t = try? b.u16(s + 2), let off = try? b.u32(s + 4) else { continue }
                type = t
                s += off
            }
            subs.append(s)
        }
        let filter = flag & 0x10 != 0 ? (try? b.u16(l + 6 + 2 * count)) : nil
        return (type, flag, filter, subs)
    }

    /// True when lookup flags say glyph `g` is skipped.
    func ignores(_ flag: Int, _ g: Int) -> Bool {
        let c = glyphClass(g)
        if flag & 2 != 0 && c == 1 { return true }
        if flag & 4 != 0 && c == 2 { return true }
        if flag & 8 != 0 && c == 3 { return true }
        if c == 3, flag & 0xFF00 != 0, let mc = markClasses, classDef(mc, g) != flag >> 8 { return true }
        return false
    }

    // MARK: GSUB

    /// Single substitution of `g` by one subtable, or nil.
    func substituteSubtable(_ s: Int, _ g: Int) -> Int? {
        guard let format = try? b.u16(s), let cov = try? b.u16(s + 2), let i = coverage(s + cov, g) else { return nil }
        if format == 1, let delta = try? b.i16(s + 4) { return (g + delta) & 0xFFFF }
        if format == 2, let n = try? b.u16(s + 4), i < n, let r = try? b.u16(s + 6 + 2 * i) { return r }
        return nil
    }

    /// The longest ligature of lookup `index` starting at `glyphs[i]`:
    /// the ligature glyph and the positions it consumes, or nil.
    func ligatureSubtable(_ s: Int, _ flag: Int, count: Int, glyph glyphAt: (Int) -> Int, at i: Int)
        -> (glyph: Int, positions: [Int])? {
        guard i < count else { return nil }
        do {
            guard let cov = try? b.u16(s + 2), let ci = coverage(s + cov, glyphAt(i)),
                  let setCount = try? b.u16(s + 4), ci < setCount, let so = try? b.u16(s + 6 + 2 * ci) else { return nil }
            let set = s + so
            guard let n = try? b.u16(set) else { return nil }
            for k in 0..<min(n, 1024) {
                guard let lo = try? b.u16(set + 2 + 2 * k), let lig = try? b.u16(set + lo),
                      let comps = try? b.u16(set + lo + 2), comps >= 1, comps <= 32 else { continue }
                var positions = [i]
                var j = i + 1
                var ok = true
                for c in 1..<comps {
                    while j < count, j - i < 64, ignores(flag, glyphAt(j)) { j += 1 }
                    guard j < count, let want = try? b.u16(set + lo + 4 + 2 * (c - 1)), want == glyphAt(j) else {
                        ok = false; break
                    }
                    positions.append(j)
                    j += 1
                }
                if ok { return (lig, positions) }
            }
        }
        return nil
    }

    // MARK: GPOS

    func anchor(_ o: Int) -> Point? {
        guard let x = try? b.i16(o + 2), let y = try? b.i16(o + 4) else { return nil }
        return Point(x: Double(x), y: Double(y))
    }

    /// For mark glyph `mark` on base `base` (types 4, 5 or 6 per `type`):
    /// the offset (base anchor − mark anchor), or nil when the lookup does not apply.
    func attach(_ index: Int, mark: Int, base: Int, component: Int = 0) -> (type: Int, offset: Point)? {
        guard let t = gpos, let l = lookup(t, index), [4, 5, 6].contains(l.type) else { return nil }
        for s in l.subtables {
            guard let mc = try? b.u16(s + 2), let bc = try? b.u16(s + 4), let classes = try? b.u16(s + 6),
                  let ma = try? b.u16(s + 8), let ba = try? b.u16(s + 10),
                  let mi = coverage(s + mc, mark), let bi = coverage(s + bc, base) else { continue }
            let markArray = s + ma
            guard let markClass = try? b.u16(markArray + 2 + 4 * mi), markClass < classes,
                  let mao = try? b.u16(markArray + 2 + 4 * mi + 2), let markAnchor = anchor(markArray + mao) else { continue }
            var baseAnchorOffset: Int?
            if l.type == 5 {
                guard let lo = try? b.u16(s + ba + 2 + 2 * bi) else { continue }
                let att = s + ba + lo
                guard let comps = try? b.u16(att), comps > 0 else { continue }
                let c = min(component, comps - 1)
                if let ao = try? b.u16(att + 2 + 2 * (c * classes + markClass)), ao != 0 { baseAnchorOffset = att + ao }
            } else {
                let rec = s + ba + 2 + 2 * (bi * classes + markClass)
                if let ao = try? b.u16(rec), ao != 0 { baseAnchorOffset = s + ba + ao }
            }
            guard let bo = baseAnchorOffset, let baseAnchor = anchor(bo) else { continue }
            return (l.type, Point(x: baseAnchor.x - markAnchor.x, y: baseAnchor.y - markAnchor.y))
        }
        return nil
    }
}

/// Applies GSUB lookups to a glyph buffer: single (1), multiple (2),
/// ligature (4), context (5) and chained context (6) substitution, formats
/// 1–3, with nested lookups (depth ≤ 8) and lookup flags. A buffer entry
/// keeps the index of the character it came from (its cluster).
struct GSUBApplier {
    struct Entry: Equatable {
        var glyph: Int
        var cluster: Int
    }

    let layout: OpenTypeLayout
    var buffer: [Entry]
    /// Work budget: substitutions and match steps, against hostile fonts.
    private var budget = 1 << 20

    init(layout: OpenTypeLayout, buffer: [Entry]) {
        self.layout = layout
        self.buffer = buffer
    }

    /// Applies lookup `index` across the buffer, only at entries `apply` accepts.
    mutating func apply(_ index: Int, where accept: (Entry) -> Bool = { _ in true }) {
        guard let table = layout.gsub, let l = layout.lookup(table, index) else { return }
        var i = 0
        while i < buffer.count && budget > 0 {
            budget -= 1
            if accept(buffer[i]), !layout.ignores(l.flag, buffer[i].glyph), let next = applyAt(l, i, depth: 0) {
                i = max(next, i + 1)
            } else {
                i += 1
            }
        }
    }

    /// Tries the lookup's subtables at `i`; returns the index after the
    /// substitution, or nil when none applied.
    private mutating func applyAt(_ l: (type: Int, flag: Int, filter: Int?, subtables: [Int]), _ i: Int, depth: Int) -> Int? {
        guard depth <= 8, i < buffer.count else { return nil }
        let b = layout.b
        let g = buffer[i].glyph
        for s in l.subtables {
            budget -= 1
            guard budget > 0, let format = try? b.u16(s) else { return nil }
            switch l.type {
            case 1:
                if let r = layout.substituteSubtable(s, g) { buffer[i].glyph = r; return i + 1 }
            case 2:
                guard let cov = try? b.u16(s + 2), let ci = layout.coverage(s + cov, g),
                      let n = try? b.u16(s + 4), ci < n, let so = try? b.u16(s + 6 + 2 * ci),
                      let count = try? b.u16(s + so), count >= 1, count <= 64 else { continue }
                var seq: [Entry] = []
                for k in 0..<count {
                    guard let r = try? b.u16(s + so + 2 + 2 * k) else { break }
                    seq.append(Entry(glyph: r, cluster: buffer[i].cluster))
                }
                guard seq.count == count, buffer.count + count < 1 << 16 else { continue }
                buffer.replaceSubrange(i...i, with: seq)
                return i + count
            case 4:
                let buf = buffer
                if let lig = layout.ligatureSubtable(s, l.flag, count: buf.count, glyph: { buf[$0].glyph }, at: i) {
                    buffer[i].glyph = lig.glyph
                    for p in lig.positions.dropFirst().reversed() { buffer.remove(at: p) }
                    return i + 1
                }
            case 5, 6:
                if let next = applyContext(l, s, format: format, chained: l.type == 6, at: i, depth: depth) { return next }
            default:
                continue
            }
        }
        return nil
    }

    /// Positions of the `count` glyphs from `i` matching `match` (skipping
    /// glyphs the flag ignores), or nil.
    private func matchForward(_ flag: Int, from i: Int, count: Int, _ match: (Int, Int) -> Bool) -> [Int]? {
        var out: [Int] = []
        var j = i
        while out.count < count {
            // Skipped glyphs are capped so a match costs O(1), not O(buffer).
            let skipStart = j
            while j < buffer.count, j - skipStart < 64, layout.ignores(flag, buffer[j].glyph) { j += 1 }
            guard j < buffer.count, match(out.count, buffer[j].glyph) else { return nil }
            out.append(j)
            j += 1
        }
        return out
    }

    private func matchBackward(_ flag: Int, from i: Int, count: Int, _ match: (Int, Int) -> Bool) -> Bool {
        var n = 0
        var j = i - 1
        while n < count {
            let skipStart = j
            while j >= 0, skipStart - j < 64, layout.ignores(flag, buffer[j].glyph) { j -= 1 }
            guard j >= 0, match(n, buffer[j].glyph) else { return false }
            n += 1
            j -= 1
        }
        return true
    }

    /// Context (5) and chained context (6) substitution, formats 1–3.
    private mutating func applyContext(_ l: (type: Int, flag: Int, filter: Int?, subtables: [Int]), _ s: Int, format: Int,
                                       chained: Bool, at i: Int, depth: Int) -> Int? {
        let b = layout.b
        let lay = layout
        let g = buffer[i].glyph
        let flag = l.flag
        func u(_ o: Int) -> Int? { try? b.u16(o) }
        /// Tries one rule: backtrack/input/lookahead matchers and its lookup records.
        func rule(_ back: [(Int) -> Bool], _ input: [(Int) -> Bool], _ ahead: [(Int) -> Bool], records: Int, count: Int)
            -> (positions: [Int], records: Int, count: Int)? {
            guard let pos = matchForward(flag, from: i, count: input.count, { input[$0]($1) }) else { return nil }
            guard matchBackward(flag, from: i, count: back.count, { back[$0]($1) }) else { return nil }
            if !ahead.isEmpty {
                guard matchForward(flag, from: (pos.last ?? i) + 1, count: ahead.count, { ahead[$0]($1) }) != nil else { return nil }
            }
            return (pos, records, count)
        }
        var found: (positions: [Int], records: Int, count: Int)?
        switch format {
        case 1:
            guard let cov = u(s + 2), let ci = layout.coverage(s + cov, g), let n = u(s + 4), ci < n,
                  let so = u(s + 6 + 2 * ci), so != 0 else { return nil }
            let set = s + so
            guard let rules = u(set) else { return nil }
            for r in 0..<min(rules, 256) where found == nil {
                guard let ro = u(set + 2 + 2 * r) else { continue }
                var p = set + ro
                var back: [(Int) -> Bool] = [], ahead: [(Int) -> Bool] = []
                if chained {
                    guard let bc = u(p) else { continue }
                    for k in 0..<min(bc, 64) { let want = u(p + 2 + 2 * k); back.append { $0 == want } }
                    p += 2 + 2 * bc
                }
                guard let ic = u(p), ic >= 1 else { continue }
                var input: [(Int) -> Bool] = [{ _ in true }]
                if chained {
                    for k in 0..<min(ic - 1, 64) { let want = u(p + 2 + 2 * k); input.append { $0 == want } }
                    p += 2 + 2 * (ic - 1)
                    guard let la = u(p) else { continue }
                    for k in 0..<min(la, 64) { let want = u(p + 2 + 2 * k); ahead.append { $0 == want } }
                    p += 2 + 2 * la
                    guard let rc = u(p) else { continue }
                    found = rule(back, input, ahead, records: p + 2, count: rc)
                } else {
                    // SubRule: glyphCount, substCount, input[glyphCount - 1], records.
                    guard let rc = u(p + 2) else { continue }
                    for k in 0..<min(ic - 1, 64) { let want = u(p + 4 + 2 * k); input.append { $0 == want } }
                    found = rule([], input, [], records: p + 4 + 2 * (ic - 1), count: rc)
                }
            }
        case 2:
            guard let cov = u(s + 2), layout.coverage(s + cov, g) != nil else { return nil }
            var p = s + 4
            var backDef = 0, aheadDef = 0
            if chained { backDef = s + (u(p) ?? 0); p += 2 }
            let inputDef = s + (u(p) ?? 0); p += 2
            if chained { aheadDef = s + (u(p) ?? 0); p += 2 }
            guard let n = u(p) else { return nil }
            let cls = layout.classDef(inputDef, g)
            guard cls < n, let so = u(p + 2 + 2 * cls), so != 0 else { return nil }
            let set = s + so
            guard let rules = u(set) else { return nil }
            for r in 0..<min(rules, 256) where found == nil {
                guard let ro = u(set + 2 + 2 * r) else { continue }
                var q = set + ro
                var back: [(Int) -> Bool] = [], ahead: [(Int) -> Bool] = []
                if chained {
                    guard let bc = u(q) else { continue }
                    for k in 0..<min(bc, 64) { let want = u(q + 2 + 2 * k); back.append { lay.classDef(backDef, $0) == want } }
                    q += 2 + 2 * bc
                }
                guard let ic = u(q), ic >= 1 else { continue }
                var input: [(Int) -> Bool] = [{ _ in true }]
                if chained {
                    for k in 0..<min(ic - 1, 64) { let want = u(q + 2 + 2 * k); input.append { lay.classDef(inputDef, $0) == want } }
                    q += 2 + 2 * (ic - 1)
                    guard let la = u(q) else { continue }
                    for k in 0..<min(la, 64) { let want = u(q + 2 + 2 * k); ahead.append { lay.classDef(aheadDef, $0) == want } }
                    q += 2 + 2 * la
                    guard let rc = u(q) else { continue }
                    found = rule(back, input, ahead, records: q + 2, count: rc)
                } else {
                    guard let rc = u(q + 2) else { continue }
                    for k in 0..<min(ic - 1, 64) { let want = u(q + 4 + 2 * k); input.append { lay.classDef(inputDef, $0) == want } }
                    found = rule([], input, [], records: q + 4 + 2 * (ic - 1), count: rc)
                }
            }
        case 3:
            var p = s + 2
            var back: [(Int) -> Bool] = [], input: [(Int) -> Bool] = [], ahead: [(Int) -> Bool] = []
            if chained {
                guard let bc = u(p) else { return nil }
                for k in 0..<min(bc, 64) { let c = s + (u(p + 2 + 2 * k) ?? 0); back.append { lay.coverage(c, $0) != nil } }
                p += 2 + 2 * bc
                guard let ic = u(p), ic >= 1 else { return nil }
                for k in 0..<min(ic, 64) { let c = s + (u(p + 2 + 2 * k) ?? 0); input.append { lay.coverage(c, $0) != nil } }
                p += 2 + 2 * ic
                guard let la = u(p) else { return nil }
                for k in 0..<min(la, 64) { let c = s + (u(p + 2 + 2 * k) ?? 0); ahead.append { lay.coverage(c, $0) != nil } }
                p += 2 + 2 * la
                guard let rc = u(p) else { return nil }
                found = rule(back, input, ahead, records: p + 2, count: rc)
            } else {
                guard let ic = u(p), ic >= 1, let rc = u(p + 2) else { return nil }
                for k in 0..<min(ic, 64) { let c = s + (u(p + 4 + 2 * k) ?? 0); input.append { lay.coverage(c, $0) != nil } }
                found = rule([], input, [], records: p + 4 + 2 * ic, count: rc)
            }
        default:
            return nil
        }
        guard let match = found else { return nil }
        // Apply the nested lookups at their input positions, tracking length changes.
        var positions = match.positions
        for r in 0..<min(match.count, 64) {
            guard let seq = u(match.records + 4 * r), let li = u(match.records + 4 * r + 2), seq < positions.count,
                  let table = layout.gsub, let nested = layout.lookup(table, li) else { continue }
            let before = buffer.count
            let at = positions[seq]
            _ = applyAt(nested, at, depth: depth + 1)
            let delta = buffer.count - before
            if delta != 0 {
                positions = positions.compactMap { $0 > at ? ($0 + delta > at ? $0 + delta : nil) : $0 }
            }
        }
        return (positions.last ?? i) + 1
    }
}
