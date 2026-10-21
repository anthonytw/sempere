import XCTest
@testable import Sempere

/// Suggested passphrases for the recovery key's passphrase copy (format.md §15.11): random BIP-39 words
/// that pass the 70-bit floor, while five words (about 55 to 65 bits) do not.
final class GeneratedPassphraseTests: XCTestCase {
    func testSuggestionsPassTheFloorAndDiffer() {
        let a = GeneratedPassphrase.make(), b = GeneratedPassphrase.make()
        XCTAssertNotEqual(a, b)
        for p in [a, b] {
            let words = p.split(separator: "-")
            XCTAssertEqual(words.count, GeneratedPassphrase.wordCount)
            XCTAssertTrue(words.allSatisfy { BIP39English.words.contains(String($0)) }, p)
            XCTAssertNil(PassphraseStrength.storedKeyProblem(p), p)
        }
    }

    func testFiveWordsAreRefused() {
        XCTAssertNotNil(PassphraseStrength.storedKeyProblem(GeneratedPassphrase.make(words: 5)))
    }
}
