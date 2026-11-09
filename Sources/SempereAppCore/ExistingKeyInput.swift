import Age
import Foundation
import Sempere

/// "Use an existing key" in the New Vault sheet: what the pasted text or the
/// picked file is (`KeyText`, shared with the CLI's `--store-key`), in words
/// the sheet shows as the user types.
public enum ExistingKeyInput {
    /// Why the input is not usable (the sheet words it: `ExistingKeyInput.message`).
    public enum Issue: Equatable, Sendable {
        /// What the text or the file is, as `KeyText` classified it.
        case key(KeyText.Problem)
        /// The file could not be read; the text is the error's description.
        case unreadable(String)
    }

    public enum Status: Equatable, Sendable {
        /// Nothing given yet.
        case empty
        /// A post-quantum secret key: it becomes the vault's recovery key.
        case ready(NativeIdentity)
        /// A passphrase-wrapped key file: its passphrase opens it (`unwrap`).
        case needsPassphrase(Data)
        /// Not usable; the problem says what it is (the sheet words it: `ExistingKeyInput.message`).
        case problem(Issue)

        public var identity: NativeIdentity? {
            if case .ready(let id) = self { return id }
            return nil
        }
    }

    /// The status of pasted text.
    public static func status(ofText text: String) -> Status {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return status(KeyText.classify(text))
    }

    /// The status of a picked file's bytes.
    public static func status(ofFile data: Data) -> Status { status(KeyText.classify(data)) }

    /// Opens a passphrase-wrapped key file (scrypt: run it off the main actor).
    public static func unwrap(_ data: Data, passphrase: String) -> Status {
        switch KeyText.unwrap(data, passphrase: passphrase) {
        case .success(let id): return .ready(id)
        case .failure(let problem): return .problem(.key(problem))
        }
    }

    private static func status(_ result: Result<KeyText.Content, KeyText.Problem>) -> Status {
        switch result {
        case .success(.identity(let id)): return .ready(id)
        case .success(.passphraseWrapped(let data)): return .needsPassphrase(data)
        case .failure(.empty): return .empty
        case .failure(let problem): return .problem(.key(problem))
        }
    }

    /// The recipient a key encrypts to, abbreviated for the sheet (`age1pq1abcd…wxyz`).
    public static func shortRecipient(_ identity: NativeIdentity) -> String {
        let key = identity.recipient.string
        return key.count > 24 ? "\(key.prefix(14))…\(key.suffix(6))" : key
    }
}
