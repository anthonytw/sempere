import XCTest
@testable import Sempere

/// Suggested passphrases for the recovery key's passphrase copy (format.md §15.11): seven distinct random BIP-39
/// words joined by hyphens. The copy takes any passphrase; the suggestion is only an offer.
final class GeneratedPassphraseTests: XCTestCase {
    func testSuggestionsAreSevenDistinctWordsAndDiffer() {
        let a = GeneratedPassphrase.make(), b = GeneratedPassphrase.make()
        XCTAssertNotEqual(a, b)
        for p in [a, b] {
            let words = p.split(separator: "-")
            XCTAssertEqual(words.count, GeneratedPassphrase.wordCount)
            XCTAssertEqual(Set(words).count, words.count, p)
            XCTAssertTrue(words.allSatisfy { BIP39English.words.contains(String($0)) }, p)
        }
    }

    func testSeededSuggestionsRepeatAndHonorTheCount() {
        var one = SplitMix64(seed: 1), two = SplitMix64(seed: 1)
        XCTAssertEqual(GeneratedPassphrase.make(words: 7, using: &one), GeneratedPassphrase.make(words: 7, using: &two))
        XCTAssertEqual(GeneratedPassphrase.make(words: 3).split(separator: "-").count, 3)
    }
}
