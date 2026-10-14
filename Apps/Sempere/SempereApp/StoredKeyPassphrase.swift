import Sempere

/// The passphrase of a key copy stored in the vault's `keys/` (format.md
/// §3.2): that file is on the vault's storage, where whoever can read it can
/// try passphrases offline, so one that is too easy to guess is refused
/// (`PassphraseStrength`, shared with the CLI; security review 2026-10,
/// stage 4, S5). The sheets that offer the copy say so.
enum StoredKeyPassphrase {
    static var footnote: String {
        String(localized: "The copy is kept in the vault, on its storage: anyone who can read the storage can try passphrases on it offline. Use five or more random words, or a long random password.",
               comment: "Footnote under the toggle that stores the key in the vault under a passphrase")
    }

    /// Shown under the fields while the passphrase is too weak; nil otherwise.
    static func warning(_ passphrase: String) -> String? {
        guard !passphrase.isEmpty, !accepts(passphrase) else { return nil }
        return String(localized: "Too easy to guess for a copy stored with the vault. Add more random words or characters.",
                      comment: "Shown while the passphrase for the stored key copy is too weak")
    }

    static func accepts(_ passphrase: String) -> Bool { PassphraseStrength.storedKeyProblem(passphrase) == nil }
}
