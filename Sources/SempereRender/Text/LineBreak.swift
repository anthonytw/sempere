import Foundation

/// Line breaking (UAX #14, Unicode 15.1, rules LB1–LB31 without tailoring).
/// Checked against the conformance file `LineBreakTest.txt`.
enum LineBreaker {
    /// A break opportunity before scalar `index` (0 < index ≤ count).
    struct Opportunity: Equatable {
        var index: Int
        /// A mandatory break (after BK, CR, LF, NL, or at the end).
        var mandatory: Bool
    }

    private struct Element {
        var cls: LineBreakClass
        /// The base character's code point (LB9 folds marks into it).
        var cp: UInt32
        /// Index of the base character.
        var start: Int
        /// The last character folded in is a ZWJ (LB8a).
        var endsWithZWJ: Bool
    }

    /// Every break opportunity in `scalars`, in order; the last one is at
    /// `scalars.count` (LB3).
    static func opportunities(_ scalars: [UInt32]) -> [Opportunity] {
        let n = scalars.count
        guard n > 0 else { return [] }
        // LB1.
        let props = UnicodeProperties.self
        let raw: [LineBreakClass] = scalars.map { c in
            switch props.lineBreak[c] {
            case .AI, .SG, .XX: return .AL
            case .SA: return ["Mn", "Mc"].contains(props.generalCategory[c]) ? .CM : .AL
            case .CJ: return .NS
            case let x: return x
            }
        }
        // LB9, LB10: marks and ZWJ fold into their base; stray ones are AL.
        var e: [Element] = []
        for i in 0..<n {
            let c = raw[i]
            if c == .CM || c == .ZWJ {
                if let last = e.last, ![.BK, .CR, .LF, .NL, .SP, .ZW].contains(last.cls) {
                    e[e.count - 1].endsWithZWJ = c == .ZWJ
                    continue
                }
                e.append(Element(cls: .AL, cp: scalars[i], start: i, endsWithZWJ: c == .ZWJ))
                continue
            }
            e.append(Element(cls: c, cp: scalars[i], start: i, endsWithZWJ: false))
        }
        var out: [Opportunity] = []
        for k in 1..<e.count {
            if let mandatory = decide(e, k) {
                out.append(Opportunity(index: e[k].start, mandatory: mandatory))
            }
        }
        out.append(Opportunity(index: n, mandatory: true))
        return out
    }

    /// Whether to break between `e[k-1]` and `e[k]`: nil for no break,
    /// true for a mandatory break, false for an opportunity.
    private static func decide(_ e: [Element], _ k: Int) -> Bool? {
        let a = e[k - 1].cls, b = e[k].cls
        let props = UnicodeProperties.self
        func cls(_ j: Int) -> LineBreakClass? { j >= 0 && j < e.count ? e[j].cls : nil }
        /// Index of the last non-SP element at or before `j`.
        func beforeSpaces(_ j: Int) -> Int {
            var i = j
            while i >= 0, e[i].cls == .SP { i -= 1 }
            return i
        }
        func isPi(_ j: Int) -> Bool { e[j].cls == .QU && props.generalCategory[e[j].cp] == "Pi" }
        func isPf(_ j: Int) -> Bool { e[j].cls == .QU && props.generalCategory[e[j].cp] == "Pf" }
        func isDotted(_ j: Int) -> Bool { j >= 0 && e[j].cp == 0x25CC }
        func akLike(_ j: Int) -> Bool { j >= 0 && (e[j].cls == .AK || e[j].cls == .AS || isDotted(j)) }
        func wide(_ j: Int) -> Bool { [.F, .W, .H].contains(props.eastAsianWidth[e[j].cp]) }

        // LB4–LB6.
        if a == .BK { return true }
        if a == .CR && b == .LF { return nil }
        if a == .CR || a == .LF || a == .NL { return true }
        if [.BK, .CR, .LF, .NL].contains(b) { return nil }
        // LB7.
        if b == .SP || b == .ZW { return nil }
        // LB8.
        let s = beforeSpaces(k - 1)
        if s >= 0, e[s].cls == .ZW { return false }
        // LB8a.
        if e[k - 1].endsWithZWJ { return nil }
        // LB11–LB13.
        if a == .WJ || b == .WJ { return nil }
        if a == .GL { return nil }
        if b == .GL && ![.SP, .BA, .HY].contains(a) { return nil }
        if [.CL, .CP, .EX, .IS, .SY].contains(b) { return nil }
        // LB14.
        if s >= 0, e[s].cls == .OP { return nil }
        // LB15a.
        if s >= 0, isPi(s), s == 0 || [.BK, .CR, .LF, .NL, .OP, .QU, .GL, .SP, .ZW].contains(e[s - 1].cls) { return nil }
        // LB15b.
        if isPf(k) {
            if k + 1 == e.count || [.SP, .GL, .WJ, .CL, .QU, .CP, .EX, .IS, .SY, .BK, .CR, .LF, .NL, .ZW]
                .contains(e[k + 1].cls) { return nil }
        }
        // LB16, LB17.
        if s >= 0, (e[s].cls == .CL || e[s].cls == .CP), b == .NS { return nil }
        if s >= 0, e[s].cls == .B2, b == .B2 { return nil }
        // LB18.
        if a == .SP { return false }
        // LB19, LB20.
        if a == .QU || b == .QU { return nil }
        if a == .CB || b == .CB { return false }
        // LB21–LB22.
        if [.BA, .HY, .NS].contains(b) || a == .BB { return nil }
        if cls(k - 2) == .HL, a == .HY || a == .BA { return nil }
        if a == .SY && b == .HL { return nil }
        if b == .IN { return nil }
        // LB23, LB23a, LB24.
        if [.AL, .HL].contains(a) && b == .NU || a == .NU && [.AL, .HL].contains(b) { return nil }
        if a == .PR && [.ID, .EB, .EM].contains(b) || [.ID, .EB, .EM].contains(a) && b == .PO { return nil }
        if [.PR, .PO].contains(a) && [.AL, .HL].contains(b) || [.AL, .HL].contains(a) && [.PR, .PO].contains(b) {
            return nil
        }
        // LB25 (numbers).
        if [.PR, .PO].contains(a) && (b == .NU || [.OP, .HY].contains(b) && cls(k + 1) == .NU) { return nil }
        if [.OP, .HY].contains(a) && b == .NU { return nil }
        func numberRunBefore(_ j: Int) -> Bool {
            var i = j, sawNU = false
            while i >= 0, [.NU, .SY, .IS].contains(e[i].cls) { if e[i].cls == .NU { sawNU = true }; i -= 1 }
            return sawNU
        }
        if [.NU, .SY, .IS, .CL, .CP].contains(b) && numberRunBefore(k - 1) && [.NU, .SY, .IS].contains(a) { return nil }
        if [.PO, .PR].contains(b) {
            var j = k - 1
            if [.CL, .CP].contains(e[j].cls) { j -= 1 }
            if j >= 0, [.NU, .SY, .IS].contains(e[j].cls), numberRunBefore(j) { return nil }
        }
        // LB26, LB27 (Korean syllables).
        if a == .JL && [.JL, .JV, .H2, .H3].contains(b) { return nil }
        if [.JV, .H2].contains(a) && [.JV, .JT].contains(b) { return nil }
        if [.JT, .H3].contains(a) && b == .JT { return nil }
        let hangul: [LineBreakClass] = [.JL, .JV, .JT, .H2, .H3]
        if hangul.contains(a) && b == .PO || a == .PR && hangul.contains(b) { return nil }
        // LB28.
        if [.AL, .HL].contains(a) && [.AL, .HL].contains(b) { return nil }
        // LB28a (Brahmic orthographic syllables).
        if a == .AP && akLike(k) { return nil }
        if akLike(k - 1) && [.VF, .VI].contains(b) { return nil }
        if a == .VI && akLike(k - 2) && (b == .AK || isDotted(k)) { return nil }
        if akLike(k - 1) && akLike(k) && cls(k + 1) == .VF { return nil }
        // LB29, LB30.
        if a == .IS && [.AL, .HL].contains(b) { return nil }
        if [.AL, .HL, .NU].contains(a) && b == .OP && !wide(k) { return nil }
        if a == .CP && !wide(k - 1) && [.AL, .HL, .NU].contains(b) { return nil }
        // LB30a: regional indicators pair up.
        if a == .RI && b == .RI {
            var count = 0, j = k - 1
            while j >= 0, e[j].cls == .RI { count += 1; j -= 1 }
            if count % 2 == 1 { return nil }
        }
        // LB30b.
        if b == .EM && (a == .EB || props.extendedPictographic[e[k - 1].cp] && props.generalCategory[e[k - 1].cp] == "Cn") {
            return nil
        }
        // LB31.
        return false
    }
}
