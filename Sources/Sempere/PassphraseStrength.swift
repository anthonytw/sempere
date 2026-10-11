import Foundation

/// How hard a passphrase is to guess, for the key copy stored in a vault's
/// `keys/` (format.md §3.2). That file sits on the sync storage, so whoever
/// can read the storage can try passphrases on it offline, as fast as scrypt
/// at the file's work factor allows (security review 2026-10, stage 4, S5).
///
/// The estimate is deliberately conservative and needs no word list: runs of
/// letters are priced as dictionary words (about 12.9 bits, one Diceware word,
/// per started nine letters, the longest Diceware words) unless guessing them letter by letter is cheaper,
/// a character equal or next to the previous one costs one bit, and word
/// separators between letter runs cost one bit. It never overestimates a
/// passphrase made of common words; it underestimates long random letter
/// strings, which only means asking for a few more characters.
public enum PassphraseStrength {
    /// The floor for a stored key copy: five random Diceware words, or about
    /// eleven random characters of mixed classes, pass.
    public static let storedKeyMinimumBits: Double = 60

    /// Bits of one Diceware word (log2 of 7776).
    static let wordBits = log2(7776.0)

    /// The estimate, in bits.
    public static func estimatedBits(_ passphrase: String) -> Double {
        let scalars = Array(passphrase.unicodeScalars)
        guard !scalars.isEmpty else { return 0 }
        let pool = poolSize(scalars)
        let perChar = log2(Double(pool))
        var total = 0.0
        var i = 0
        var previous: Unicode.Scalar?
        // Cost of one character after `previous`, letter by letter.
        func charCost(_ s: Unicode.Scalar, after p: Unicode.Scalar?) -> Double {
            if let p, abs(Int(s.value) - Int(p.value)) <= 1 { return 1 }
            return perChar
        }
        // A digit or symbol read as a letter ("Tr0ub4dor"), next to a letter, belongs to the word.
        func wordLike(_ k: Int) -> Bool {
            if isLetter(scalars[k]) { return true }
            guard leet.contains(scalars[k]) else { return false }
            return (k > 0 && isLetter(scalars[k - 1])) || (k + 1 < scalars.count && isLetter(scalars[k + 1]))
        }
        while i < scalars.count {
            let s = scalars[i]
            if wordLike(i) {
                var j = i
                var byChar = 0.0
                var p = previous
                var upper = false
                var substitutions = 0.0
                while j < scalars.count, wordLike(j) {
                    byChar += charCost(scalars[j], after: p)
                    if CharacterSet.uppercaseLetters.contains(scalars[j]) { upper = true }
                    if !isLetter(scalars[j]) { substitutions += 1 }
                    p = scalars[j]
                    j += 1
                }
                let length = j - i
                let asWords = Double((length + 8) / 9) * wordBits + (upper ? 1 : 0) + substitutions
                total += min(byChar, asWords)
                previous = scalars[j - 1]
                i = j
            } else {
                let separator = s == " " || s == "-" || s == "_" || s == "." || s == ","
                let betweenWords = separator && i > 0 && isLetter(scalars[i - 1]) && i + 1 < scalars.count
                    && isLetter(scalars[i + 1])
                total += betweenWords ? 1 : charCost(s, after: previous)
                previous = s
                i += 1
            }
        }
        return total
    }

    /// Why `passphrase` is too weak for a key copy stored in the vault, or nil.
    public static func storedKeyProblem(_ passphrase: String) -> String? {
        let bits = estimatedBits(passphrase)
        guard bits < storedKeyMinimumBits else { return nil }
        return "the passphrase is too easy to guess for a key stored in the vault (about \(Int(bits)) bits, at least "
            + "\(Int(storedKeyMinimumBits)) needed): whoever can read the vault's storage can try passphrases offline. "
            + "Use five or more random words, or a long random password"
    }

    static func isLetter(_ s: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(s) }

    /// Characters commonly typed for letters (`0` for o, `4` for a, `$` for s...).
    static let leet: Set<Unicode.Scalar> = ["0", "1", "3", "4", "5", "7", "@", "$", "!", "|"]

    /// The alphabet the characters present suggest.
    static func poolSize(_ scalars: [Unicode.Scalar]) -> Int {
        var lower = false, upper = false, digit = false, symbol = false, other = false
        for s in scalars {
            switch s.value {
            case 0x61...0x7A: lower = true
            case 0x41...0x5A: upper = true
            case 0x30...0x39: digit = true
            case 0x20...0x7E: symbol = true
            default: other = true
            }
        }
        return (lower ? 26 : 0) + (upper ? 26 : 0) + (digit ? 10 : 0) + (symbol ? 33 : 0) + (other ? 100 : 0)
    }
}
