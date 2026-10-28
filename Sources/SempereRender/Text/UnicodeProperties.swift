import Foundation

/// A Unicode property as a run table (`UnicodeTables`): the code space cut
/// into runs of one value, looked up by binary search. Parsed once, on first use.
struct RunTable<Value: Sendable>: Sendable {
    private let starts: [UInt32]
    private let values: [Value]

    /// Parses `start:index,...` (base 36) with `names[index]` mapped by `map`.
    init(runs: String, names: [String], map: (String) -> Value) {
        let mapped = names.map(map)
        var s: [UInt32] = [], v: [Value] = []
        for run in runs.split(separator: ",") {
            let parts = run.split(separator: ":")
            // The tables are generated: a malformed one is a build error caught by the tests.
            let start = UInt32(parts[0], radix: 36) ?? 0, index = Int(parts[1], radix: 36) ?? 0
            s.append(start)
            v.append(mapped[min(index, mapped.count - 1)])
        }
        starts = s
        values = v
    }

    subscript(_ c: UInt32) -> Value {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= c { lo = mid } else { hi = mid - 1 }
        }
        return values[lo]
    }

    subscript(_ s: Unicode.Scalar) -> Value { self[s.value] }
}

/// Bidi_Class (UAX #9).
enum BidiClass: String, Sendable, CaseIterable {
    case L, R, AL, EN, ES, ET, AN, CS, NSM, BN, B, S, WS, ON, LRE, LRO, RLE, RLO, PDF, LRI, RLI, FSI, PDI
}

/// Line_Break (UAX #14), Unicode 15.1.
enum LineBreakClass: String, Sendable, CaseIterable {
    case BK, CR, LF, NL, SP, ZW, WJ, GL, CB, CL, CP, EX, IN, NS, OP, QU, IS, NU, PO, PR, SY, AI, AK, AL, AP, AS,
         B2, BA, BB, CJ, CM, EB, EM, H2, H3, HL, HY, ID, JL, JT, JV, RI, SA, SG, VF, VI, XX, ZWJ
}

/// East_Asian_Width.
enum EastAsianWidth: String, Sendable { case N, A, F, H, Na, W }

/// Joining_Type (Arabic and Syriac shaping).
enum JoiningType: String, Sendable { case U, R, L, D, C, T }

/// The Unicode properties text layout needs (`docs/attachments.md` §6).
enum UnicodeProperties {
    static let bidiClass = RunTable(runs: UnicodeTables.bidiClassRuns, names: UnicodeTables.bidiClassNames) {
        BidiClass(rawValue: $0) ?? .L
    }
    static let lineBreak = RunTable(runs: UnicodeTables.lineBreakRuns, names: UnicodeTables.lineBreakNames) {
        LineBreakClass(rawValue: $0) ?? .XX
    }
    static let eastAsianWidth = RunTable(runs: UnicodeTables.eastAsianWidthRuns,
                                         names: UnicodeTables.eastAsianWidthNames) { EastAsianWidth(rawValue: $0) ?? .N }
    static let generalCategory = RunTable(runs: UnicodeTables.generalCategoryRuns,
                                          names: UnicodeTables.generalCategoryNames) { $0 }
    static let script = RunTable(runs: UnicodeTables.scriptRuns, names: UnicodeTables.scriptNames) { $0 }
    static let joiningType = RunTable(runs: UnicodeTables.joiningTypeRuns, names: UnicodeTables.joiningTypeNames) {
        JoiningType(rawValue: $0) ?? .U
    }
    static let extendedPictographic = RunTable(runs: UnicodeTables.extendedPictographicRuns,
                                               names: UnicodeTables.extendedPictographicNames) { $0 == "Y" }

    /// Bidi_Paired_Bracket: open → close and close → open, with the type.
    static let brackets: [UInt32: (pair: UInt32, open: Bool)] = {
        var out: [UInt32: (UInt32, Bool)] = [:]
        for entry in UnicodeTables.bidiBrackets.split(separator: ",") {
            let p = entry.split(separator: ":")
            guard p.count == 3, let a = UInt32(p[0], radix: 36), let b = UInt32(p[1], radix: 36) else { continue }
            out[a] = (b, p[2] == "o")
        }
        return out
    }()

    /// Bidi_Mirroring_Glyph.
    static let mirror: [UInt32: UInt32] = {
        var out: [UInt32: UInt32] = [:]
        for entry in UnicodeTables.bidiMirroring.split(separator: ",") {
            let p = entry.split(separator: ":")
            guard p.count == 2, let a = UInt32(p[0], radix: 36), let b = UInt32(p[1], radix: 36) else { continue }
            out[a] = b
        }
        return out
    }()

    /// Mn, Mc or Me.
    static func isMark(_ c: UInt32) -> Bool { generalCategory[c].hasPrefix("M") }
}
