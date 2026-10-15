import Foundation

/// How hard a passphrase is to guess, for the key copy stored in a vault's
/// `keys/` (format.md §3.2). That file sits on the sync storage, so whoever
/// can read the storage can try passphrases on it offline, as fast as scrypt
/// at the file's work factor allows (security review 2026-10, stage 4, S5).
///
/// The estimate is conservative and needs no word list. It splits the
/// passphrase into runs of letters (with digits and symbols typed for letters,
/// `Tr0ub4dor`) and other characters, and prices each run by the cheapest way
/// an attacker could guess it:
///
/// - Letter by letter, from the character classes present; a character equal
///   or next to the previous one (`aaa`, `abc`, `123`, across a word separator
///   too) costs one bit, and one continuing a walk of three or more
///   neighbouring keys (`qwerty`, `1qaz`) two bits.
/// - As dictionary words, about 12.9 bits (one Diceware word) per started nine
///   letters, when the run reads like English: its letter trigram cost
///   (`LetterTrigrams`, from Webster's Second) is low. A run of letters that
///   does not read like words is priced letter by letter, or, when it is
///   pronounceable (no more than two consonants or vowels in a row, like the
///   syllables of Apple's generated passwords), by consonant (log2 20) and
///   vowel (log2 6). Runs with letters outside a–z are always priced as words.
/// - A run repeating an earlier one (ignoring case) costs one bit, a
///   passphrase that repeats one part (`abcabc`) that part plus log2 of the
///   count, and a very common password (`password`, `qwerty`, …) eight bits.
///
/// Word separators between letter runs cost one bit. Apple's generated
/// passwords (`xxxxxx-xxxxxx-xxxxxx`, consonant-vowel syllables, one digit and
/// one capital; about 71 bits, Apple Platform Security) are credited with that
/// figure, less a Diceware word's worth for each group that reads like a word.
///
/// It underestimates rather than overestimates: a passphrase of common words
/// is priced as words, so five random words are needed, and a random password
/// needs about twelve to sixteen characters (fewer with more character classes).
public enum PassphraseStrength {
    /// The floor for a stored key copy: five random Diceware words, an Apple
    /// generated password, or about twelve random characters of mixed
    /// classes (sixteen lowercase letters), pass.
    public static let storedKeyMinimumBits: Double = 60

    /// Something the estimate found that made a passphrase cheaper to guess,
    /// for a live list of hints. In display order.
    public enum Finding: String, Sendable, CaseIterable, Hashable {
        /// A very common password (`password`, `qwerty`, `letmein`, …).
        case commonPassword
        /// A walk of neighbouring keys (`qwerty`, `asdf`, `1qaz2wsx`).
        case keyboardPattern
        /// A run like `abc`, `123` or `aaa`.
        case sequence
        /// A repeated word or part (`lunar lunar`, `abcabc`).
        case repetition
        /// Runs that read like dictionary words (each counts as one word).
        case dictionaryWords
    }

    /// The estimate and what lowered it.
    public struct Assessment: Sendable, Equatable {
        /// The estimate, in bits.
        public var bits: Double
        /// What made it cheaper, in `Finding` order.
        public var findings: [Finding]
        /// True when `bits` reaches `storedKeyMinimumBits`.
        public var meetsStoredKeyFloor: Bool { bits >= PassphraseStrength.storedKeyMinimumBits }
    }

    /// Bits of one Diceware word (log2 of 7776).
    static let wordBits = log2(7776.0)
    /// Apple's figure for its generated passwords (Apple Platform Security, "Automatic strong passwords").
    static let appleGeneratedBits = 71.0
    /// A letter run whose trigram cost per letter (and end) is at most this reads like a word.
    static let wordlikeCost = 4.9
    /// A long run that splits into words costing at most this per letter (and word end) reads like words.
    static let segmentedWordlikeCost = 4.3
    /// Stricter, for the groups of an Apple-shaped password: one at most this is taken for a word.
    static let appleGroupWordCost = 4.0
    /// Longer input is estimated from its start: the estimate is far above the floor by then.
    static let maximumScalars = 4096

    /// The estimate, in bits.
    public static func estimatedBits(_ passphrase: String) -> Double { assess(passphrase).bits }

    /// The estimate and the findings that lowered it.
    public static func assess(_ passphrase: String) -> Assessment {
        let scalars = Array(passphrase.unicodeScalars.prefix(maximumScalars))
        var found: Set<Finding> = []
        var bits = estimate(scalars, found: &found)
        if let apple = appleShapedBits(scalars) { bits = max(bits, apple) }
        return Assessment(bits: bits, findings: Finding.allCases.filter(found.contains))
    }

    /// Why `passphrase` is too weak for a key copy stored in the vault, or nil.
    public static func storedKeyProblem(_ passphrase: String) -> String? {
        let bits = estimatedBits(passphrase)
        guard bits < storedKeyMinimumBits else { return nil }
        return "the passphrase is too easy to guess for a key stored in the vault (about \(Int(bits)) bits, at least "
            + "\(Int(storedKeyMinimumBits)) needed): whoever can read the vault's storage can try passphrases offline. "
            + "Use five or more random words, or a long random password"
    }

    // MARK: - The estimate

    private static func estimate(_ scalars: [Unicode.Scalar], found: inout Set<Finding>) -> Double {
        guard !scalars.isEmpty else { return 0 }
        if let period = smallestPeriod(scalars) {
            found.insert(.repetition)
            return estimate(Array(scalars[..<period]), found: &found) + log2(Double(scalars.count / period))
        }
        let n = scalars.count
        let perChar = log2(Double(poolSize(scalars)))
        let walk = keyboardWalk(scalars, found: &found)
        var sequenceLength = 0
        // The cost of character k after `previous` when it continues a pattern, else nil.
        func patternCost(_ k: Int, after previous: Unicode.Scalar?) -> Double? {
            if let previous, abs(Int(scalars[k].value) - Int(previous.value)) <= 1 {
                sequenceLength += 1
                if sequenceLength >= 2 { found.insert(.sequence) }
                return 1
            }
            sequenceLength = 0
            return walk[k] ? 2 : nil
        }
        // A digit or symbol read as a letter ("Tr0ub4dor", "p@$$w0rd"), joined to a letter
        // directly or through other such characters, belongs to the word.
        var wordLikeAt = scalars.map(isLetter)
        var k = 0
        while k < n {
            guard !wordLikeAt[k], leet[scalars[k]] != nil else { k += 1; continue }
            var j = k
            while j < n, !wordLikeAt[j], leet[scalars[j]] != nil { j += 1 }
            if (k > 0 && wordLikeAt[k - 1]) || (j < n && wordLikeAt[j]) {
                for m in k..<j { wordLikeAt[m] = true }
            }
            k = j
        }
        func wordLike(_ k: Int) -> Bool { wordLikeAt[k] }
        var total = 0.0
        var i = 0
        var previous: Unicode.Scalar?
        var runs: Set<String> = []
        while i < n {
            if wordLike(i) {
                var j = i
                var byChar = 0.0, bySyllable = 0.0, extra = 0.0
                var upper = false
                var p = previous
                while j < n, wordLike(j) {
                    let s = scalars[j]
                    if let cheap = patternCost(j, after: p) {
                        byChar += cheap
                        bySyllable += cheap
                    } else {
                        byChar += perChar
                        bySyllable += isVowel(leet[s] ?? s) ? log2(6.0) : log2(20.0)
                    }
                    if CharacterSet.uppercaseLetters.contains(s) { upper = true }
                    if !isLetter(s) { extra += 1 }
                    p = s
                    j += 1
                }
                if upper { extra += 1 }
                let run = String(String.UnicodeScalarView(scalars[i..<j])).lowercased()
                let letters = run.unicodeScalars.map { leet[$0] ?? $0 }
                let price: Double
                if !runs.insert(run).inserted {
                    found.insert(.repetition)
                    price = 1
                } else {
                    var best = lettersPrice(letters, byChar: byChar, bySyllable: bySyllable, extra: extra, found: &found)
                    if let common = commonPassword(in: letters) {
                        // Eight bits for the common part, the rest as letters of its own ("password1", "iloveyouforever").
                        found.insert(.commonPassword)
                        var rest = letters
                        rest.removeSubrange(common)
                        let restByChar = Double(rest.count) * perChar
                        let restBySyllable = rest.reduce(0.0) { $0 + (isVowel($1) ? log2(6.0) : log2(20.0)) }
                        let restPrice = rest.isEmpty ? 0
                            : lettersPrice(rest, byChar: restByChar, bySyllable: restBySyllable, extra: 0, found: &found)
                        best = min(best, 8 + extra + restPrice)
                    }
                    price = best
                }
                total += price
                previous = scalars[j - 1]
                i = j
            } else {
                let s = scalars[i]
                let separator = s == " " || s == "-" || s == "_" || s == "." || s == ","
                let betweenWords = separator && i > 0 && isLetter(scalars[i - 1]) && i + 1 < n
                    && isLetter(scalars[i + 1])
                if betweenWords {
                    // Between words the next letter is compared with the last one ("a a a").
                    total += 1
                } else {
                    total += patternCost(i, after: previous) ?? perChar
                    previous = s
                }
                i += 1
            }
        }
        return total
    }

    /// The price of a run of letters (substitutions read as their letters) that
    /// is not a repeat: letter by letter (`byChar`), as dictionary words when it
    /// reads like words, by syllables when it is pronounceable.
    private static func lettersPrice(_ letters: [Unicode.Scalar], byChar: Double, bySyllable: Double, extra: Double,
                                     found: inout Set<Finding>) -> Double {
        let asWords = Double((letters.count + 8) / 9) * wordBits + extra
        guard let codes = letterCodes(letters), !readsLikeWords(codes) else {
            if asWords < byChar && letters.count >= 3 { found.insert(.dictionaryWords) }
            return min(byChar, asWords)
        }
        return pronounceable(letters) ? min(byChar, bySyllable + extra) : byChar
    }

    /// The smallest period of a passphrase made of two or more copies of one part (ignoring case), or nil.
    static func smallestPeriod(_ scalars: [Unicode.Scalar]) -> Int? {
        let folded = scalars.map { lowercased($0) }
        let n = folded.count
        guard n >= 2 else { return nil }
        for period in 1...(n / 2) where n % period == 0 {
            if (period..<n).allSatisfy({ folded[$0] == folded[$0 - period] }) { return period }
        }
        return nil
    }

    // MARK: - Letters

    static func isLetter(_ s: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(s) }

    static func isVowel(_ s: Unicode.Scalar) -> Bool { "aeiouyAEIOUY".unicodeScalars.contains(s) }

    static func lowercased(_ s: Unicode.Scalar) -> Unicode.Scalar {
        (0x41...0x5A).contains(s.value) ? Unicode.Scalar(s.value + 0x20) ?? s : s
    }

    /// Characters commonly typed for letters (`0` for o, `4` for a, `$` for s...), and the letter.
    static let leet: [Unicode.Scalar: Unicode.Scalar] = [
        "0": "o", "1": "l", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i", "|": "l",
    ]

    /// No more than two consonants or two vowels in a row.
    static func pronounceable(_ letters: [Unicode.Scalar]) -> Bool {
        var consonants = 0, vowels = 0
        for s in letters {
            if isVowel(s) { vowels += 1; consonants = 0 } else { consonants += 1; vowels = 0 }
            if consonants > 2 || vowels > 2 { return false }
        }
        return true
    }

    /// The letters a–z of a run as 0...25, or nil when it holds anything else.
    static func letterCodes(_ letters: [Unicode.Scalar]) -> [Int]? {
        var codes: [Int] = []
        codes.reserveCapacity(letters.count)
        for s in letters {
            let v = Int(lowercased(s).value)
            guard (0x61...0x7A).contains(v) else { return nil }
            codes.append(v - 0x61)
        }
        return codes
    }

    /// The letter trigram cost of one word (start and end included), in half bits.
    static func trigramHalfBits(_ codes: ArraySlice<Int>) -> Int {
        let table = trigramTable
        var a = 0, b = 0   // "^^": contexts count a–z from 1
        var halfBits = 0
        for next in codes {
            halfBits += Int(table[(a * 27 + b) * 27 + next])
            a = b
            b = next + 1
        }
        return halfBits + Int(table[(a * 27 + b) * 27 + 26])
    }

    /// The trigram cost per letter and word end of a run read as one word, in bits.
    static func trigramCostPerLetter(_ codes: [Int]) -> Double {
        Double(trigramHalfBits(codes[...])) / 2 / Double(codes.count + 1)
    }

    /// The same for the cheapest split of the run into words of up to 20
    /// letters (`correcthorsebatterystaple`), each word end counted.
    static func segmentedCostPerLetter(_ codes: [Int]) -> Double {
        let n = codes.count
        guard n > 0 else { return 0 }
        var best = [(halfBits: Int, words: Int)](repeating: (Int.max, 0), count: n + 1)
        best[0] = (0, 0)
        for end in 1...n {
            for start in max(0, end - 20)..<end where best[start].halfBits != Int.max {
                let cost = best[start].halfBits + trigramHalfBits(codes[start..<end])
                if cost < best[end].halfBits { best[end] = (cost, best[start].words + 1) }
            }
        }
        return Double(best[n].halfBits) / 2 / Double(n + best[n].words)
    }

    /// Whether a run of letters reads like English words: as one word, or,
    /// for a long run, as several run together.
    static func readsLikeWords(_ codes: [Int]) -> Bool {
        guard !codes.isEmpty else { return false }
        if trigramCostPerLetter(codes) <= wordlikeCost { return true }
        return codes.count >= 10 && segmentedCostPerLetter(codes) <= segmentedWordlikeCost
    }

    /// `LetterTrigrams.encoded` decoded: half bits per (context, next) cell.
    static let trigramTable: [UInt8] = LetterTrigrams.encoded.utf8.map { $0 &- 48 }

    /// Very common passwords and password words, after undoing letter substitutions.
    static let commonPasswords: Set<String> = [
        "password", "passwort", "contrasena", "qwerty", "qwertz", "azerty", "letmein", "iloveyou", "admin",
        "welcome", "monkey", "dragon", "sunshine", "princess", "football", "baseball", "soccer", "master",
        "shadow", "superman", "batman", "trustno", "login", "starwars", "whatever", "freedom", "hello",
        "secret", "summer", "winter", "spring", "autumn", "abc", "asdf", "zxcvbnm", "pokemon", "charlie",
        "michael", "jordan", "hunter", "ranger", "buster", "killer", "cheese", "computer", "internet",
        "sempere", "changeme", "default", "test", "guest",
    ]

    /// Where the longest very common password in the run is, if any (the
    /// whole run, or a part of four letters or more).
    static func commonPassword(in letters: [Unicode.Scalar]) -> Range<Int>? {
        let run = letters.map { lowercased($0) }
        if commonPasswords.contains(String(String.UnicodeScalarView(run))) { return 0..<run.count }
        var best: Range<Int>?
        for word in commonPasswords where word.count >= 4 && word.count <= run.count && word.count > (best?.count ?? 0) {
            let w = Array(word.unicodeScalars)
            if let start = (0...(run.count - w.count)).first(where: { run[$0..<($0 + w.count)].elementsEqual(w) }) {
                best = start..<(start + w.count)
            }
        }
        return best
    }

    // MARK: - Keyboard walks

    /// For each character, true when it continues a walk of three or more
    /// neighbouring keys on a US keyboard (shifted keys count as their key).
    static func keyboardWalk(_ scalars: [Unicode.Scalar], found: inout Set<Finding>) -> [Bool] {
        var walk = [Bool](repeating: false, count: scalars.count)
        var k = 1
        while k < scalars.count {
            var j = k
            while j < scalars.count, keysAdjacent(scalars[j - 1], scalars[j]) { j += 1 }
            if j - k >= 2 {
                for m in k..<j { walk[m] = true }
                if j - k >= 3 { found.insert(.keyboardPattern) }
            }
            k = max(j, k + 1)
        }
        return walk
    }

    static let keyRows = ["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"]
    static let shifted = Array("~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:\"ZXCVBNM<>?".unicodeScalars)
    static let unshifted = Array("`1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./".unicodeScalars)

    /// Row and column (rows shifted half a key each) of every key.
    static let keyPositions: [Unicode.Scalar: (row: Int, column: Double)] = {
        var positions: [Unicode.Scalar: (row: Int, column: Double)] = [:]
        for (row, keys) in keyRows.enumerated() {
            for (column, key) in keys.unicodeScalars.enumerated() {
                positions[key] = (row, Double(column) + 0.5 * Double(row))
            }
        }
        for (shiftedKey, key) in zip(shifted, unshifted) { positions[shiftedKey] = positions[key] }
        return positions
    }()

    static func keysAdjacent(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        guard let p = keyPositions[a], let q = keyPositions[b] else { return false }
        if p.row == q.row && p.column == q.column { return false }
        return abs(p.row - q.row) <= 1 && abs(p.column - q.column) <= 1
    }

    // MARK: - Apple generated passwords

    /// Apple's format: three groups of six letters and digits joined by `-`,
    /// one digit and one capital in all, each group consonant-vowel-consonant-
    /// consonant-vowel-consonant (the digit taking any place). Credited with
    /// Apple's 71 bits, less the difference between a pronounceable group and
    /// a dictionary word for each group that reads like a word. Nil for any
    /// other shape.
    static func appleShapedBits(_ scalars: [Unicode.Scalar]) -> Double? {
        guard scalars.count == 20, scalars[6] == "-", scalars[13] == "-" else { return nil }
        var digits = 0, capitals = 0
        var wordlikeGroups = 0
        for start in [0, 7, 14] {
            var letters: [Unicode.Scalar] = []
            for (place, s) in scalars[start..<(start + 6)].enumerated() {
                switch s.value {
                case 0x30...0x39:
                    // Read as the letter it may stand for (`kit7en`), for the word check only.
                    digits += 1
                    if let letter = leet[s] { letters.append(letter) }
                    continue
                case 0x41...0x5A: capitals += 1
                case 0x61...0x7A: break
                default: return nil
                }
                let lower = lowercased(s)
                guard isVowel(lower) == (place == 1 || place == 4) else { return nil }
                letters.append(lower)
            }
            guard let codes = letterCodes(letters) else { return nil }
            if trigramCostPerLetter(codes) <= appleGroupWordCost { wordlikeGroups += 1 }
        }
        guard digits == 1, capitals == 1 else { return nil }
        let pronounceableGroup = 4 * log2(20.0) + 2 * log2(6.0)
        return appleGeneratedBits - Double(wordlikeGroups) * (pronounceableGroup - wordBits)
    }

    // MARK: - Character classes

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
