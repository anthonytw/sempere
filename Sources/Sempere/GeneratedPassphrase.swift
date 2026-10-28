import Foundation

/// A passphrase for the recovery key's passphrase copy (format.md §15.11) that a user does not have to
/// invent: distinct random words of the BIP-39 English list (2048 words, 11 bits each), joined by hyphens.
/// Seven words carry 77 bits. It is an offer, not a requirement: the copy takes any passphrase.
public enum GeneratedPassphrase {
    /// The number of words a suggestion has.
    public static let wordCount = 7

    /// `count` distinct words drawn uniformly (the system's cryptographically secure generator), joined by "-".
    public static func make(words count: Int = wordCount) -> String {
        var rng = SystemRandomNumberGenerator()
        return make(words: count, using: &rng)
    }

    /// `make(words:)` with the given generator (tests pass a seeded one).
    static func make<G: RandomNumberGenerator>(words count: Int, using rng: inout G) -> String {
        let wanted = min(max(count, 1), BIP39English.words.count)
        var picked: [Int] = []
        while picked.count < wanted {
            let index = Int(rng.next(upperBound: UInt64(BIP39English.words.count)))
            if !picked.contains(index) { picked.append(index) }
        }
        return picked.map { BIP39English.words[$0] }.joined(separator: "-")
    }
}
