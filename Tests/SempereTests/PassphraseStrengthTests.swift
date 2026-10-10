import Foundation
import XCTest
@testable import Sempere

/// The floor for a key copy stored in the vault (security review 2026-10,
/// stage 4, S5): the file is on the sync storage and can be guessed offline.
final class PassphraseStrengthTests: XCTestCase {
    func testCommonAndShortPassphrasesAreRefused() {
        for weak in ["", "s3cret", "sempere-test", "password1234", "Tr0ub4dor&3", "correct horse battery staple",
                     "correcthorsebatterystaple", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "abcdefghijklmnopqrstuvwxyz",
                     "1234567890123456", "Summer2026!", "smoke test passphrase"] {
            XCTAssertNotNil(PassphraseStrength.storedKeyProblem(weak), "\(weak): \(PassphraseStrength.estimatedBits(weak))")
        }
    }

    func testFiveRandomWordsOrALongRandomPasswordPass() {
        for strong in ["correct horse battery staple orbit", "lunar-pickle-tundra-mosaic-quiver",
                       "q7R#mK2v!pZx9%Lw", "J8t%wQ1z&Lr4nV^6", "Vela 47 cobre; tilde 902 ámbar!"] {
            XCTAssertNil(PassphraseStrength.storedKeyProblem(strong), "\(strong): \(PassphraseStrength.estimatedBits(strong))")
        }
    }

    func testTheEstimateIsMonotonicInAddedRandomWords() {
        let words = ["lunar", "pickle", "tundra", "mosaic", "quiver", "falcon"]
        var last = -1.0
        for n in 1...words.count {
            let bits = PassphraseStrength.estimatedBits(words.prefix(n).joined(separator: " "))
            XCTAssertGreaterThan(bits, last)
            last = bits
        }
    }
}
