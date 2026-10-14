import Foundation

/// Fractional-index keys for page `order` (format.md §5.5).
///
/// Keys are strings over the base-62 alphabet `0-9A-Za-z` (ASCII order), so
/// plain string comparison sorts them. Generated keys never end in `0`, which
/// guarantees there is always room for another key on either side.
public enum PageOrder {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    static let digitOf: [UInt8: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    /// A key strictly between `a` and `b`; nil means an open end
    /// (`between(nil, nil)` is the first page's key).
    ///
    /// Inserting at the front, at the back, or repeatedly just after the
    /// previously inserted key steps by one digit rather than bisecting, so
    /// those common sequences keep keys short (about one character per 30
    /// inserts). Alternating inserts into one shrinking gap bisect and grow
    /// about one character per 6 inserts. If no key fits
    /// (`a >= b`, characters outside the alphabet, or `b` is `a` followed only
    /// by `0`s) the result is a key just after `a`; the caller should then
    /// re-key a neighbour.
    public static func between(_ a: String?, _ b: String?) -> String {
        if let key = strictlyBetween(a ?? "", b) { return key }
        return (a ?? "") + "V"
    }

    static func strictlyBetween(_ a: String, _ b: String?) -> String? {
        guard let lower = digits(a) else { return nil }
        var upper: [Int]?
        if let b {
            guard let d = digits(b), a < b else { return nil }
            upper = d
        }
        var out: [Int] = []
        var tightLow = true          // prefix so far equals a's prefix
        var tightHigh = upper != nil // prefix so far equals b's prefix
        var i = 0
        while true {
            let loOpen = !tightLow || i >= lower.count
            let lo = loOpen ? -1 : lower[i]
            var hi = 62
            if tightHigh, let upper {
                guard i < upper.count else { return nil }  // b would be a prefix of the result
                hi = upper[i]
            }
            if hi - lo >= 2 {
                let d: Int
                switch (loOpen, tightHigh) {
                case (false, true): d = (lo + hi) / 2               // bounded both sides: bisect
                case (true, true): d = a.isEmpty ? hi - 1            // prepend: step down
                                                 : (hi > 1 ? max(1, (lo + hi) / 2) : 0)
                case (false, false): d = lo + 1                      // after a, below b: step up
                case (true, false): d = 31
                }
                out.append(d)
                if d > 0 { break }
                // d == 0 only from (open, hi == 1): keep going below b.
                tightLow = false
                tightHigh = false
            } else if lo == hi {
                out.append(lo)
            } else if lo == -1 {
                // a ended (or is already below) and b has `0` here.
                out.append(0)
                tightLow = false
            } else {
                // hi == lo + 1: follow a, now strictly below b.
                out.append(lo)
                tightHigh = false
            }
            i += 1
        }
        return String(decoding: out.map { alphabet[$0] }, as: UTF8.self)
    }

    private static func digits(_ s: String) -> [Int]? {
        var out: [Int] = []
        for byte in s.utf8 {
            guard let d = digitOf[byte] else { return nil }
            out.append(d)
        }
        return out
    }
}
