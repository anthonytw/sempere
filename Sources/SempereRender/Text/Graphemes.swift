import Foundation

/// Extended grapheme clusters (UAX #29, Unicode 15.1, rules GB3–GB999), from
/// the same UCD as the other tables rather than the standard library's
/// (whose version varies by toolchain). Checked against `GraphemeBreakTest.txt`.
enum GraphemeClusters {
    private enum GCB: String { case XX, CN, CR, EX, L, LF, LV, LVT, PP, RI, SM, T, V, ZWJ }
    private enum InCB: String { case None, Consonant, Extend, Linker }

    private static let gcb = RunTable(runs: UnicodeTables.graphemeBreakRuns, names: UnicodeTables.graphemeBreakNames) {
        GCB(rawValue: $0) ?? .XX
    }
    private static let incb = RunTable(runs: UnicodeTables.indicConjunctBreakRuns,
                                       names: UnicodeTables.indicConjunctBreakNames) { InCB(rawValue: $0) ?? .None }

    /// Scalar offsets where a cluster ends (the last is `scalars.count`).
    static func boundaries(_ scalars: [UInt32]) -> [Int] {
        let n = scalars.count
        guard n > 0 else { return [] }
        let p = scalars.map { gcb[$0] }
        let ext = scalars.map { UnicodeProperties.extendedPictographic[$0] }
        let ic = scalars.map { incb[$0] }
        var out: [Int] = []
        var riRun = 0                    // regional indicators in a row ending at i - 1
        var pictZWJ = false              // GB11: ExtPict Extend* ZWJ ends at i - 1
        var pictExtend = false           // ExtPict Extend* ends at i - 1
        var conjunct = 0                 // GB9c: 1 after Consonant [Extend|Linker]*, 2 once a Linker followed
        for i in 1...n {
            let a = p[i - 1]
            riRun = a == .RI ? riRun + 1 : 0
            let wasPictExtend = pictExtend
            pictExtend = ext[i - 1] || (pictExtend && a == .EX)
            pictZWJ = a == .ZWJ && wasPictExtend
            switch ic[i - 1] {
            case .Consonant: conjunct = 1
            case .Linker: conjunct = conjunct > 0 ? 2 : 0
            case .Extend: break
            case .None: conjunct = 0
            }
            guard i < n else { out.append(n); break }
            let b = p[i]
            let breaks: Bool
            if a == .CR && b == .LF { breaks = false }                                              // GB3
            else if [.CN, .CR, .LF].contains(a) || [.CN, .CR, .LF].contains(b) { breaks = true }    // GB4, GB5
            else if a == .L && [.L, .V, .LV, .LVT].contains(b) { breaks = false }                   // GB6
            else if [.LV, .V].contains(a) && [.V, .T].contains(b) { breaks = false }                // GB7
            else if [.LVT, .T].contains(a) && b == .T { breaks = false }                            // GB8
            else if b == .EX || b == .ZWJ || b == .SM || a == .PP { breaks = false }                // GB9–GB9b
            else if conjunct == 2 && ic[i] == .Consonant { breaks = false }                         // GB9c
            else if pictZWJ && ext[i] { breaks = false }                                            // GB11
            else if a == .RI && b == .RI && riRun % 2 == 1 { breaks = false }                       // GB12, GB13
            else { breaks = true }                                                                  // GB999
            if breaks { out.append(i) }
        }
        return out
    }
}
