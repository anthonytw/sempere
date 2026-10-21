import Sempere

/// The passphrase of a key copy stored in the vault's `keys/` (format.md
/// §3.2): that file is on the vault's storage, where whoever can read it can
/// try passphrases offline, so one that is too easy to guess is refused
/// (`PassphraseStrength`, shared with the CLI; security review 2026-10,
/// stage 4, S5). The sheets that offer the copy say so, and list what is
/// still missing as the user types (`requirements`, `hints`).
enum StoredKeyPassphrase {
    static var footnote: String {
        String(localized: "The copy is kept in the vault, on its storage: anyone who can read the storage can try passphrases on it offline. Use Suggest a Passphrase (seven random words), six or more random words of your own, a password from your password manager, or about 16 random characters.",
               comment: "Footnote under the toggle that stores the key in the vault under a passphrase")
    }

    /// Shown under the fields while the passphrase is too weak; nil otherwise.
    static func warning(_ passphrase: String) -> String? {
        guard !passphrase.isEmpty, !accepts(passphrase) else { return nil }
        return String(localized: "Too easy to guess for a copy stored with the vault. Add more random words or characters.",
                      comment: "Shown while the passphrase for the stored key copy is too weak")
    }

    static func accepts(_ passphrase: String) -> Bool { PassphraseStrength.storedKeyProblem(passphrase) == nil }

    /// One line of the live checklist under the passphrase fields.
    struct Requirement: Identifiable, Equatable {
        enum Kind: String { case strength, match }
        let kind: Kind
        let text: String
        let met: Bool
        var id: String { kind.rawValue }
    }

    /// What the passphrase pair still needs, updated as the user types:
    /// the strength estimate against the floor, and the two entries matching.
    static func requirements(_ passphrase: String, confirmation: String) -> [Requirement] {
        let assessment = PassphraseStrength.assess(passphrase)
        let bits = Int(assessment.bits.rounded(.down))
        let floor = Int(PassphraseStrength.storedKeyMinimumBits)
        return [
            Requirement(kind: .strength,
                        text: String(localized: "Hard to guess: about \(bits) of \(floor) bits",
                                     comment: "Checklist line; first %lld is the estimated strength in bits, second the minimum"),
                        met: assessment.meetsStoredKeyFloor),
            Requirement(kind: .match,
                        text: String(localized: "Both entries match", comment: "Checklist line: passphrase and its repetition are equal"),
                        met: !passphrase.isEmpty && passphrase == confirmation),
        ]
    }

    /// How far the estimate is towards the floor, 0...1, for a meter.
    static func progress(_ passphrase: String) -> Double {
        min(1, max(0, PassphraseStrength.estimatedBits(passphrase) / PassphraseStrength.storedKeyMinimumBits))
    }

    /// Why the passphrase is cheaper to guess than its length suggests, while it is too weak.
    static func hints(_ passphrase: String) -> [String] {
        guard !passphrase.isEmpty else { return [] }
        let assessment = PassphraseStrength.assess(passphrase)
        guard !assessment.meetsStoredKeyFloor else { return [] }
        return assessment.findings.map { finding in
            switch finding {
            case .commonPassword:
                return String(localized: "It contains a very common password, which is guessed first.",
                              comment: "Passphrase hint")
            case .keyboardPattern:
                return String(localized: "It contains a keyboard pattern, like “qwerty” or “1qaz”.", comment: "Passphrase hint")
            case .sequence:
                return String(localized: "It contains a sequence or repeated characters, like “abc”, “123” or “aaa”.",
                              comment: "Passphrase hint")
            case .repetition:
                return String(localized: "It repeats a word or part.", comment: "Passphrase hint")
            case .dictionaryWords:
                return String(localized: "Words count as words, not as letters: use six or more random words.",
                              comment: "Passphrase hint")
            }
        }
    }
}
