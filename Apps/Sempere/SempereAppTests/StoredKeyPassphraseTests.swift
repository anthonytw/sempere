import Testing
@testable import SempereApp

/// The New Vault and Upgrade Vault sheets refuse a passphrase too easy to
/// guess for a key copy stored with the vault (security review 2026-10,
/// stage 4, S5), and say why.
struct StoredKeyPassphraseTests {
    @Test func weakPassphrasesAreRefusedWithAReason() {
        #expect(!StoredKeyPassphrase.accepts("sempere-test"))
        #expect(StoredKeyPassphrase.warning("sempere-test") != nil)
        #expect(StoredKeyPassphrase.warning("") == nil, "nothing typed yet: no warning")
        #expect(StoredKeyPassphrase.accepts("lunar-pickle-tundra-mosaic-quiver"))
        #expect(StoredKeyPassphrase.warning("lunar-pickle-tundra-mosaic-quiver") == nil)
    }
}
