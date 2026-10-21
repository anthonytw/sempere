import Foundation

/// A passphrase for the recovery key's passphrase copy (format.md §15.11) that a user does not have to
/// invent: random words of the BIP-39 English list (2048 words, 11 bits each), joined by hyphens.
/// Seven words carry 77 bits, above the 70-bit floor (`PassphraseStrength.storedKeyMinimumBits`, design
/// §8.2), and the estimate prices them as words, so they pass it too.
public enum GeneratedPassphrase {
    /// The number of words a suggestion has.
    public static let wordCount = 7

    /// `count` words drawn uniformly (the system's cryptographically secure generator), joined by "-".
    public static func make(words count: Int = wordCount) -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<max(count, 1)).map { _ in
            BIP39English.words[Int(rng.next(upperBound: UInt64(BIP39English.words.count)))]
        }.joined(separator: "-")
    }
}
