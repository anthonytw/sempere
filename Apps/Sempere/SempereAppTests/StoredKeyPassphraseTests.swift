import Sempere
import Testing
@testable import SempereApp

/// The New Vault sheet refuses a passphrase too easy to
/// guess for a key copy stored with the vault (security review 2026-10,
/// stage 4, S5), and says why.
struct StoredKeyPassphraseTests {
    @Test func weakPassphrasesAreRefusedWithAReason() {
        #expect(!StoredKeyPassphrase.accepts("sempere-test"))
        #expect(StoredKeyPassphrase.warning("sempere-test") != nil)
        #expect(StoredKeyPassphrase.warning("") == nil, "nothing typed yet: no warning")
        #expect(StoredKeyPassphrase.accepts("lunar-pickle-tundra-mosaic-quiver-banjo"))
        #expect(StoredKeyPassphrase.warning("lunar-pickle-tundra-mosaic-quiver-banjo") == nil)
        // Five random words (about 65 bits) stay under the 70-bit floor.
        #expect(!StoredKeyPassphrase.accepts("lunar-pickle-tundra-mosaic-quiver"))
    }

    /// Suggest a Passphrase: seven random words of the BIP-39 list (77 bits), which pass the floor.
    @Test func suggestedPassphrasesPassTheFloorAndDiffer() {
        let a = GeneratedPassphrase.make(), b = GeneratedPassphrase.make()
        #expect(a != b)
        #expect(a.split(separator: "-").count == GeneratedPassphrase.wordCount)
        for p in [a, b] + (0..<20).map({ _ in GeneratedPassphrase.make() }) {
            #expect(StoredKeyPassphrase.accepts(p), "\(p)")
        }
    }
}
