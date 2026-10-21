import Foundation
import XCTest
@testable import Sempere

/// The floor for a key copy stored in the vault (security review 2026-10,
/// stage 4, S5): the file is on the sync storage and can be guessed offline.
final class PassphraseStrengthTests: XCTestCase {
    func testCommonAndShortPassphrasesAreRefused() {
        for weak in ["", "s3cret", "sempere-test", "password1234", "Tr0ub4dor&3", "correct horse battery staple",
                     "correcthorsebatterystaple", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "abcdefghijklmnopqrstuvwxyz",
                     "1234567890123456", "Summer2026!", "smoke test passphrase", "P@ssw0rd2026!",
                     "ILoveYouForeverAndEver", "antidisestablishmentarianism", "thequickbrownfoxjumpsoverthelazydog"] {
            XCTAssertNotNil(PassphraseStrength.storedKeyProblem(weak), "\(weak): \(PassphraseStrength.estimatedBits(weak))")
        }
    }

    /// Repeats across separators cost what repeats cost anywhere else (B20).
    func testRepeatedWordsAndLettersBetweenSeparatorsAreRefused() {
        for weak in ["a a a a a a a a a a", "aaaaaaaaa aaaaaaaaa aaaaaaaaa aaaaaaaaa aaaaaaaaa",
                     "password password password password password", "Lunar-lunar-LUNAR-lunar-lunar-lunar",
                     "abcabcabcabcabcabc", "xkqxkqxkqxkqxkqxkqxkqxkq", "P@ssw0rd!P@ssw0rd!", "Password-Password-1",
                     "q7R#mK2v!q7R#mK2v!"] {
            XCTAssertNotNil(PassphraseStrength.storedKeyProblem(weak), "\(weak): \(PassphraseStrength.estimatedBits(weak))")
        }
    }

    func testKeyboardWalksAreRefused() {
        for weak in ["qwertyuiopasdfghjkl", "qwertyuiop1234567890", "1qaz2wsx3edc4rfv", "zxcvbnmasdfghjkl",
                     "qazwsxedcrfvtgbyhn", "mnbvcxzlkjhgfdsa", "QWERTYUIOP!@#$%^&*()", "poiuytrewq0987654321"] {
            XCTAssertNotNil(PassphraseStrength.storedKeyProblem(weak), "\(weak): \(PassphraseStrength.estimatedBits(weak))")
        }
    }

    /// The floor is about 70 bits (key-hierarchy design §8.2): six random words, a long random password,
    /// or an Apple generated one pass.
    func testSixRandomWordsOrALongRandomPasswordPass() {
        for strong in ["correct horse battery staple orbit lantern", "lunar-pickle-tundra-mosaic-quiver-falcon",
                       "q7R#mK2v!pZx9%Lw", "J8t%wQ1z&Lr4nV^6", "Vela 47 cobre; tilde 902 ámbar!",
                       "xkqvbmzrtwplhgfdnc", "vuspot-Bekfu4-qobqag"] {
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

    // MARK: - Corpus

    /// Apple's automatic strong passwords: consonant-vowel syllables in three
    /// groups of six, one digit and one capital (about 71 bits). The owner's
    /// report (c26): every one used to come out near 43 bits.
    func testAppleGeneratedPasswordsPass() {
        var rng = SplitMix64(seed: 26)
        var passed = 0, lowest = Double.infinity
        let samples = 2000
        for _ in 0..<samples {
            let password = Self.appleStyle(&rng)
            let bits = PassphraseStrength.estimatedBits(password)
            if bits >= PassphraseStrength.storedKeyMinimumBits { passed += 1 }
            lowest = min(lowest, bits)
        }
        // At the 70-bit floor of the passphrase copy (key-hierarchy design §8.2) a group that reads like a
        // word costs a Diceware word, so about one in ten falls short (measured 91 %).
        XCTAssertGreaterThanOrEqual(Double(passed) / Double(samples), 0.9, "\(passed) of \(samples)")
        XCTAssertGreaterThan(lowest, 50)
    }

    /// The same shape made of real words gets no Apple credit.
    func testAppleShapedRealWordsAreRefused() {
        for weak in ["Summer-butte4-kitten", "tablet-Button-kitte7", "bonbon-Kit7en-pepper", "Hammer-ladder-pupp3t"] {
            XCTAssertNotNil(PassphraseStrength.storedKeyProblem(weak), "\(weak): \(PassphraseStrength.estimatedBits(weak))")
        }
    }

    func testSixToEightDicewareWordsPassAndFiveDoNot() {
        var rng = SplitMix64(seed: 5)
        for count in 6...8 {
            for separator in [" ", "-", ".", "_"] {
                for _ in 0..<200 {
                    let phrase = (0..<count).map { _ in Self.words[Int(rng.next() % UInt64(Self.words.count))] }
                        .joined(separator: separator)
                    // Drawing the same word twice is a weaker phrase; the estimate rightly charges it.
                    guard Set(phrase.split(separator: Character(separator))).count == count else { continue }
                    XCTAssertNil(PassphraseStrength.storedKeyProblem(phrase),
                                 "\(phrase): \(PassphraseStrength.estimatedBits(phrase))")
                }
            }
        }
        // Five random words are about 65 bits: refused, nearly always (measured 94 %).
        var refused = 0
        for _ in 0..<500 {
            let phrase = (0..<5).map { _ in Self.words[Int(rng.next() % UInt64(Self.words.count))] }.joined(separator: " ")
            if PassphraseStrength.storedKeyProblem(phrase) != nil { refused += 1 }
        }
        XCTAssertGreaterThanOrEqual(refused, 450)
    }

    func testLongRandomPasswordsPass() {
        var rng = SplitMix64(seed: 16)
        let printable = Array((0x21...0x7E).compactMap(Unicode.Scalar.init).map(Character.init))
        let lower = Array("abcdefghijklmnopqrstuvwxyz")
        // At the 70-bit floor (design §8.2): random printable passwords of 20 or more characters always pass,
        // 16 nearly always.
        var passedPrintable16 = 0
        for length in 16...24 {
            for _ in 0..<100 {
                let password = String((0..<length).map { _ in printable[Int(rng.next() % UInt64(printable.count))] })
                if length >= 20 {
                    XCTAssertNil(PassphraseStrength.storedKeyProblem(password),
                                 "\(password): \(PassphraseStrength.estimatedBits(password))")
                } else if length == 16, PassphraseStrength.storedKeyProblem(password) == nil {
                    passedPrintable16 += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(passedPrintable16, 90)
        // Twenty-four random lowercase letters (113 bits) always pass; twenty (94 bits) nearly always.
        var passed20 = 0
        for _ in 0..<300 {
            let long = String((0..<24).map { _ in lower[Int(rng.next() % 26)] })
            XCTAssertNil(PassphraseStrength.storedKeyProblem(long), "\(long): \(PassphraseStrength.estimatedBits(long))")
            let twenty = String((0..<20).map { _ in lower[Int(rng.next() % 26)] })
            if PassphraseStrength.storedKeyProblem(twenty) == nil { passed20 += 1 }
        }
        XCTAssertGreaterThanOrEqual(passed20, 240)
    }

    // MARK: - Findings

    func testFindingsNameWhatLoweredTheEstimate() {
        XCTAssertTrue(PassphraseStrength.assess("qwertyuiop").findings.contains(.keyboardPattern))
        XCTAssertTrue(PassphraseStrength.assess("password123").findings.contains(.commonPassword))
        XCTAssertTrue(PassphraseStrength.assess("p@$$w0rd").findings.contains(.commonPassword))
        XCTAssertTrue(PassphraseStrength.assess("abcabcabc").findings.contains(.repetition))
        XCTAssertTrue(PassphraseStrength.assess("lunar lunar").findings.contains(.repetition))
        XCTAssertTrue(PassphraseStrength.assess("xk9 12345").findings.contains(.sequence))
        XCTAssertTrue(PassphraseStrength.assess("lunar pickle").findings.contains(.dictionaryWords))
        XCTAssertEqual(PassphraseStrength.assess("q7R#mK2v!pZx9%Lw").findings, [])
        XCTAssertEqual(PassphraseStrength.assess("").bits, 0)
        XCTAssertFalse(PassphraseStrength.assess("").meetsStoredKeyFloor)
        XCTAssertFalse(PassphraseStrength.assess("lunar-pickle-tundra-mosaic-quiver").meetsStoredKeyFloor, "five words")
        XCTAssertTrue(PassphraseStrength.assess("lunar-pickle-tundra-mosaic-quiver-falcon").meetsStoredKeyFloor)
    }

    // MARK: - Robustness

    func testTheTrigramTableIsComplete() {
        XCTAssertEqual(PassphraseStrength.trigramTable.count, 27 * 27 * 27)
        XCTAssertTrue(PassphraseStrength.trigramTable.allSatisfy { $0 <= 30 })
    }

    func testHugeAndOddInputIsBoundedAndNeverTraps() {
        var rng = SplitMix64(seed: 1)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let huge = String((0..<1_000_000).map { _ in letters[Int(rng.next() % 26)] })
        let start = Date()
        XCTAssertGreaterThan(PassphraseStrength.estimatedBits(huge), 60)
        // Only its start is read: a repeated part is still a repetition.
        XCTAssertLessThan(PassphraseStrength.estimatedBits(String(repeating: "xk9#", count: 250_000)), 60)
        XCTAssertGreaterThan(PassphraseStrength.estimatedBits(String(repeating: "a", count: 1_000_000)), 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        for odd in ["\u{0}", "\u{FFFF}", "🔑🔑🔑", "e\u{301}", "\u{10FFFF}a", "-", " a ", "ñandú ñandú", "ÅÄÖ-åäö"] {
            _ = PassphraseStrength.assess(odd)
        }
    }

    // MARK: - Generators

    /// Apple's format as documented (Apple Platform Security, "Automatic strong passwords").
    static func appleStyle(_ rng: inout SplitMix64) -> String {
        let consonants = Array("bcdfghjkmnpqrstvwxz"), vowels = Array("aeiouy")
        var groups: [[Character]] = (0..<3).map { _ in
            "CVCCVC".map { slot in
                let pool = slot == "C" ? consonants : vowels
                return pool[Int(rng.next() % UInt64(pool.count))]
            }
        }
        var places = (0..<18).map { ($0 / 6, $0 % 6) }
        let digit = places.remove(at: Int(rng.next() % UInt64(places.count)))
        let capital = places[Int(rng.next() % UInt64(places.count))]
        groups[digit.0][digit.1] = Character(String(rng.next() % 10))
        groups[capital.0][capital.1] = Character(groups[capital.0][capital.1].uppercased())
        return groups.map { String($0) }.joined(separator: "-")
    }

    /// Everyday words of three to nine letters, as in a Diceware list.
    static let words = """
        acid acorn actor afar agile album alley amber anchor angle ankle apple apron arch arena armor arrow \
        aspen atlas attic audio autumn avocado bacon badge bagel baker bamboo banjo barn basil basket beach \
        beard beaver bench berry bicycle bison blanket blaze blender bloom bonnet bottle boulder bracket \
        breeze brick bridge broom bucket bugle burrow butter cabin cactus camel candle canoe canyon carbon \
        carpet castle cedar cellar cement chalk cherry chimney cider circus clover cobalt cocoa comet copper \
        coral cosmos cotton coyote crater crayon cricket crystal cupcake curtain dagger daisy dancer denim \
        desert dinner doctor dolphin donkey dragon drawer drizzle eagle easel echo eclipse elbow ember engine \
        falcon fender ferry fiddle finch flannel flute forest fossil fountain fridge galaxy garden garlic \
        gazelle geyser ginger glacier goblet granite gravel guitar hammock harbor harvest hazel helmet heron \
        hockey honey hornet igloo island ivory jacket jaguar jasmine jelly jigsaw jungle kettle kidney kiwi \
        ladder lagoon lantern laptop lemon lilac linen lizard lobster locket lunar magnet mango marble meadow \
        melon mitten mosaic muffin mustard napkin nectar needle noodle nutmeg oasis ocean olive onion orbit \
        orchid otter oyster paddle palace panda parrot pebble pepper pickle pilot pillow pinball planet \
        plaza pocket polka pony poppy potato prism pumpkin puzzle quarry quill quiver rabbit radar raisin \
        ranch raven razor ribbon river rocket rodeo saddle salmon sandal satin scarf shovel silver skillet \
        sleet sloth socket sonnet spider sponge squash staple statue sunset swamp tablet tadpole teapot \
        thimble thunder tiger toast tomato tractor trumpet tulip tundra turtle umbrella valley velvet violin \
        walnut walrus wizard yogurt zebra zipper
        """.split(separator: " ").map(String.init)
}
