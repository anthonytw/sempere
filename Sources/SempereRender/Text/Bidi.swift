import Foundation

/// The Unicode Bidirectional Algorithm (UAX #9, Unicode 15.1) for one
/// paragraph: embedding levels (rules P2–P3, X1–X10, W1–W7, N0–N2, I1–I2)
/// and the visual order of a line (L1–L2). Checked against the Unicode
/// conformance files `BidiTest.txt` and `BidiCharacterTest.txt`.
///
/// Characters removed by rule X9 (embedding controls and BN) get the level
/// of the character before them, as the reference implementation does.
struct BidiParagraph {
    /// The paragraph embedding level: 0 (left to right) or 1.
    let level: Int
    /// The resolved level of each character.
    let levels: [UInt8]
    /// Each character's original Bidi_Class (for L1).
    let classes: [BidiClass]

    static let maxDepth = 125

    /// Resolves a paragraph (no paragraph separator inside except at the end).
    /// `direction`: nil for automatic (P2–P3), else 0 or 1.
    init(_ scalars: [UInt32], direction: Int?) {
        self.init(scalars, classes: scalars.map { UnicodeProperties.bidiClass[$0] }, direction: direction)
    }

    /// As `init(_:direction:)` with given classes (the conformance tests give classes only).
    init(_ scalars: [UInt32], classes: [BidiClass], direction: Int?) {
        let n = classes.count
        self.classes = classes
        let matchingPDI = Self.matchIsolates(classes)
        let para = direction ?? Self.firstStrongLevel(classes, 0, n, matchingPDI) ?? 0
        level = para
        guard n > 0 else { levels = []; return }

        // X1–X8.
        var types = classes
        var lv = [Int](repeating: para, count: n)
        struct Entry { var level: Int; var override: BidiClass?; var isolate: Bool }
        var stack = [Entry(level: para, override: nil, isolate: false)]
        var overflowIsolates = 0, overflowEmbeddings = 0, validIsolates = 0
        for i in 0..<n {
            let t = classes[i]
            let top = stack[stack.count - 1]
            switch t {
            case .RLE, .LRE, .RLO, .LRO:
                lv[i] = top.level
                let rtl = t == .RLE || t == .RLO
                let next = rtl ? (top.level + 1) | 1 : (top.level + 2) & ~1
                if next <= Self.maxDepth && overflowIsolates == 0 && overflowEmbeddings == 0 {
                    stack.append(Entry(level: next, override: t == .RLO ? .R : t == .LRO ? .L : nil, isolate: false))
                } else if overflowIsolates == 0 {
                    overflowEmbeddings += 1
                }
            case .RLI, .LRI, .FSI:
                lv[i] = top.level
                if let o = top.override { types[i] = o }
                var rtl = t == .RLI
                if t == .FSI {
                    rtl = Self.firstStrongLevel(classes, i + 1, matchingPDI[i] ?? n, matchingPDI) == 1
                }
                let next = rtl ? (top.level + 1) | 1 : (top.level + 2) & ~1
                if next <= Self.maxDepth && overflowIsolates == 0 && overflowEmbeddings == 0 {
                    validIsolates += 1
                    stack.append(Entry(level: next, override: nil, isolate: true))
                } else {
                    overflowIsolates += 1
                }
            case .PDI:
                if overflowIsolates > 0 {
                    overflowIsolates -= 1
                } else if validIsolates > 0 {
                    overflowEmbeddings = 0
                    while let last = stack.last, !last.isolate { stack.removeLast() }
                    stack.removeLast()
                    validIsolates -= 1
                }
                let now = stack[stack.count - 1]
                lv[i] = now.level
                if let o = now.override { types[i] = o }
            case .PDF:
                lv[i] = top.level
                if overflowIsolates > 0 {
                } else if overflowEmbeddings > 0 {
                    overflowEmbeddings -= 1
                } else if !top.isolate && stack.count >= 2 {
                    stack.removeLast()
                }
            case .B:
                lv[i] = para
            case .BN:
                lv[i] = top.level
            default:
                lv[i] = top.level
                if let o = top.override { types[i] = o }
            }
        }

        // X9: removed characters take no part in what follows.
        func removed(_ i: Int) -> Bool {
            switch classes[i] {
            case .RLE, .LRE, .RLO, .LRO, .PDF, .BN: return true
            default: return false
            }
        }
        let kept = (0..<n).filter { !removed($0) }

        // X10: level runs, then isolating run sequences (BD13).
        var runs: [[Int]] = []
        for i in kept {
            if let last = runs.last?.last, lv[last] == lv[i] { runs[runs.count - 1].append(i) } else { runs.append([i]) }
        }
        var runOf = [Int](repeating: -1, count: n)
        for (r, run) in runs.enumerated() { for i in run { runOf[i] = r } }
        var matchingInitiator = [Int: Int]()
        for (a, b) in matchingPDI.enumerated() { if let b { matchingInitiator[b] = a } }
        var sequences: [[Int]] = []
        for run in runs {
            if let first = run.first, classes[first] == .PDI, matchingInitiator[first] != nil { continue }
            var seq = run
            var current = run
            while let last = current.last, [.LRI, .RLI, .FSI].contains(classes[last]), let pdi = matchingPDI[last],
                  runOf[pdi] >= 0 {
                current = runs[runOf[pdi]]
                seq += current
            }
            sequences.append(seq)
        }
        let keptIndex: [Int: Int] = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })

        // sos and eos compare explicit levels: I1–I2 below must not leak into them.
        let explicit = lv
        for seq in sequences {
            let level = explicit[seq[0]]
            guard let k0 = keptIndex[seq[0]], let k1 = keptIndex[seq[seq.count - 1]] else { continue }
            let before = k0 > 0 ? explicit[kept[k0 - 1]] : para
            let lastIsUnmatchedIsolate = [.LRI, .RLI, .FSI].contains(classes[seq[seq.count - 1]])
                && matchingPDI[seq[seq.count - 1]] == nil
            let after = (k1 + 1 < kept.count && !lastIsUnmatchedIsolate) ? explicit[kept[k1 + 1]] : para
            let sos: BidiClass = max(level, before) % 2 == 1 ? .R : .L
            let eos: BidiClass = max(level, after) % 2 == 1 ? .R : .L
            Self.resolveSequence(seq, types: &types, original: classes, scalars: scalars, level: level, sos: sos, eos: eos)
            // I1–I2.
            for i in seq {
                let t = types[i]
                if level % 2 == 0 {
                    if t == .R { lv[i] = level + 1 } else if t == .AN || t == .EN { lv[i] = level + 2 }
                } else if t == .L || t == .EN || t == .AN {
                    lv[i] = level + 1
                }
            }
        }
        // Removed characters: the level of the character before them.
        for i in 0..<n where removed(i) { lv[i] = i > 0 ? lv[i - 1] : para }
        levels = lv.map { UInt8($0) }
    }

    /// P2–P3 over `start..<end`: 1 for R or AL first, 0 for L, nil for none
    /// (skipping isolates up to their matching PDI).
    static func firstStrongLevel(_ c: [BidiClass], _ start: Int, _ end: Int, _ matchingPDI: [Int?]) -> Int? {
        var i = start
        while i < end {
            switch c[i] {
            case .L: return 0
            case .R, .AL: return 1
            case .LRI, .RLI, .FSI:
                guard let m = matchingPDI[i] else { return nil }
                i = m
            case .B: return nil
            default: break
            }
            i += 1
        }
        return nil
    }

    /// BD9: for each isolate initiator, its matching PDI (nil when unmatched
    /// and for every other character).
    static func matchIsolates(_ c: [BidiClass]) -> [Int?] {
        var out = [Int?](repeating: nil, count: c.count)
        var open: [Int] = []
        for (i, t) in c.enumerated() {
            switch t {
            case .LRI, .RLI, .FSI: open.append(i)
            case .PDI: if let o = open.popLast() { out[o] = i }
            case .B: open.removeAll()
            default: break
            }
        }
        return out
    }

    private static func isStrongR(_ t: BidiClass) -> Bool { t == .R || t == .EN || t == .AN }

    /// W1–W7, N0–N2 over one isolating run sequence.
    static func resolveSequence(_ seq: [Int], types: inout [BidiClass], original: [BidiClass], scalars: [UInt32],
                                level: Int, sos: BidiClass, eos: BidiClass) {
        let m = seq.count
        var t = seq.map { types[$0] }
        // W1.
        for k in 0..<m where t[k] == .NSM {
            if k == 0 { t[k] = sos } else { t[k] = [.LRI, .RLI, .FSI, .PDI].contains(t[k - 1]) ? .ON : t[k - 1] }
        }
        // W2, W3.
        var lastStrong = sos
        for k in 0..<m {
            switch t[k] {
            case .L, .R, .AL: lastStrong = t[k]
            case .EN: if lastStrong == .AL { t[k] = .AN }
            default: break
            }
        }
        for k in 0..<m where t[k] == .AL { t[k] = .R }
        // W4.
        if m >= 3 {
            for k in 1..<(m - 1) {
                if t[k] == .ES, t[k - 1] == .EN, t[k + 1] == .EN { t[k] = .EN }
                else if t[k] == .CS, t[k - 1] == .EN, t[k + 1] == .EN { t[k] = .EN }
                else if t[k] == .CS, t[k - 1] == .AN, t[k + 1] == .AN { t[k] = .AN }
            }
        }
        // W5.
        var k = 0
        while k < m {
            if t[k] == .ET {
                var e = k
                while e < m, t[e] == .ET { e += 1 }
                if (k > 0 && t[k - 1] == .EN) || (e < m && t[e] == .EN) {
                    for j in k..<e { t[j] = .EN }
                }
                k = e
            } else {
                k += 1
            }
        }
        // W6.
        for k in 0..<m where [.ES, .ET, .CS].contains(t[k]) { t[k] = .ON }
        // W7.
        lastStrong = sos
        for k in 0..<m {
            switch t[k] {
            case .L, .R: lastStrong = t[k]
            case .EN: if lastStrong == .L { t[k] = .L }
            default: break
            }
        }
        // N0: bracket pairs (BD16).
        let e: BidiClass = level % 2 == 0 ? .L : .R
        var pairs: [(Int, Int)] = []
        if !scalars.isEmpty {
            var stack: [(closer: UInt32, pos: Int)] = []
            scan: for k in 0..<m where t[k] == .ON {
                var c = scalars[seq[k]]
                if c == 0x2329 { c = 0x3008 } else if c == 0x232A { c = 0x3009 }
                guard let b = UnicodeProperties.brackets[c] else { continue }
                if b.open {
                    if stack.count == 63 { break scan }
                    var closer = b.pair
                    if closer == 0x232A { closer = 0x3009 }
                    stack.append((closer, k))
                } else if let j = stack.lastIndex(where: { $0.closer == c }) {
                    pairs.append((stack[j].pos, k))
                    stack.removeSubrange(j...)
                }
            }
            pairs.sort { $0.0 < $1.0 }
        }
        func strong(_ x: BidiClass) -> BidiClass? { x == .L ? .L : isStrongR(x) ? .R : nil }
        for (open, close) in pairs {
            var foundE = false, foundO = false
            for j in (open + 1)..<close {
                guard let s = strong(t[j]) else { continue }
                if s == e { foundE = true; break } else { foundO = true }
            }
            var newType: BidiClass?
            if foundE {
                newType = e
            } else if foundO {
                var context = sos
                var j = open - 1
                while j >= 0 { if let s = strong(t[j]) { context = s; break }; j -= 1 }
                newType = context != e ? context : e
            }
            if let nt = newType {
                t[open] = nt; t[close] = nt
                for b in [open, close] {
                    var j = b + 1
                    while j < m, original[seq[j]] == .NSM { t[j] = nt; j += 1 }
                }
            }
        }
        // N1–N2.
        func isNI(_ x: BidiClass) -> Bool { [.B, .S, .WS, .ON, .LRI, .RLI, .FSI, .PDI].contains(x) }
        k = 0
        while k < m {
            guard isNI(t[k]) else { k += 1; continue }
            var end = k
            while end < m, isNI(t[end]) { end += 1 }
            let lead: BidiClass = k == 0 ? sos : (strong(t[k - 1]) ?? e)
            let trail: BidiClass = end == m ? eos : (strong(t[end]) ?? e)
            let resolved = lead == trail ? lead : e
            for j in k..<end { t[j] = resolved }
            k = end
        }
        for (j, i) in seq.enumerated() { types[i] = t[j] }
    }

    /// L1–L2: the logical indices of `range` (one line) in visual order, left
    /// to right. Characters removed by X9 are kept (at the level L1 gives them).
    func visualOrder(_ range: Range<Int>) -> [Int] {
        // L1 on the line's own levels (work proportional to the line).
        let line = lineLevels(range)
        func lvOf(_ i: Int) -> Int { Int(line[i - range.lowerBound]) }
        var order = Array(range)
        guard let maxLevel = range.map({ lvOf($0) }).max() else { return order }
        let minOdd = (range.map { lvOf($0) }.filter { $0 % 2 == 1 }.min()) ?? maxLevel + 1
        var l = maxLevel
        while l >= minOdd && l > 0 {
            var k = 0
            while k < order.count {
                if lvOf(order[k]) >= l {
                    var e = k
                    while e < order.count, lvOf(order[e]) >= l { e += 1 }
                    order[k..<e].reverse()
                    k = e
                } else {
                    k += 1
                }
            }
            l -= 1
        }
        return order
    }

    /// The level of each character of `range` after L1 (what decides a
    /// run's direction on that line).
    func lineLevels(_ range: Range<Int>) -> [UInt8] {
        var lv = Array(levels[range])
        let base = range.lowerBound
        var trailing = true
        for i in range.reversed() {
            let c = classes[i]
            if c == .S || c == .B { lv[i - base] = UInt8(level); trailing = true }
            else if [.WS, .FSI, .LRI, .RLI, .PDI, .BN, .RLE, .LRE, .RLO, .LRO, .PDF].contains(c) {
                if trailing { lv[i - base] = UInt8(level) }
            } else { trailing = false }
        }
        return lv
    }
}
