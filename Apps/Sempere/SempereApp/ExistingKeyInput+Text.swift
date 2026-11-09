import Foundation
import Sempere
import SempereAppCore

/// The words of "Use an existing key" (`ExistingKeyInput`, in `SempereAppCore`, holds the status rules).
extension ExistingKeyInput {
    /// The words for an issue.
    static func message(_ issue: Issue) -> String {
        switch issue {
        case .key(let problem): return message(problem)
        case .unreadable(let detail): return String(localized: "Sempere could not read that file: \(detail)")
        }
    }

    /// What the sheet says for each problem; `KeyText.Problem.description` is the CLI's English.
    static func message(_ problem: KeyText.Problem) -> String {
        switch problem {
        case .empty:
            return String(localized: "Paste a secret key or choose a key file.", comment: "Existing key field is empty")
        case .tooLarge:
            return String(localized: "That is too large to be a key. A key file is a few kilobytes at most.",
                          comment: "Existing key input is too large")
        case .publicKey(let key):
            return String(localized: "\(key) is a public key: it cannot open the vault. Paste the secret key (AGE-SECRET-KEY-PQ-1…) instead.",
                          comment: "%@ is the abbreviated age1pq1… public key the user pasted")
        case .classicPublicKey(let key):
            return String(localized: "\(key) is a classic age1… public key, which is not quantum-safe. Vaults take only post-quantum keys (AGE-SECRET-KEY-PQ-1…, from age-keygen -pq or sempere keys generate).",
                          comment: "%@ is the classic age1… public key the user pasted")
        case .classicSecretKey:
            return String(localized: "That is a classic AGE-SECRET-KEY-1… key, which is not quantum-safe. Vaults take only post-quantum keys (AGE-SECRET-KEY-PQ-1…, from age-keygen -pq or sempere keys generate).",
                          comment: "The user pasted a classic X25519 secret key")
        case .damagedSecretKey:
            return String(localized: "The AGE-SECRET-KEY-PQ-1… key is incomplete or mistyped. Copy all of it.",
                          comment: "Existing key does not decode")
        case .mismatchedPublicKey:
            return String(localized: "The “public key” line does not belong to the secret key: this is not one key file.",
                          comment: "age-keygen output whose public key comment names another key")
        case .severalSecretKeys(let count):
            return String(localized: "That holds \(count) different secret keys. Give only one.",
                          comment: "%lld is the number of secret keys found")
        case .encryptedToKeys:
            return String(localized: "That file is encrypted to keys, not to a passphrase: it is not a key file.",
                          comment: "Picked an age file not protected by a passphrase")
        case .damagedFile:
            return String(localized: "That key file is damaged.", comment: "Picked key file cannot be read")
        case .wrongPassphrase:
            return String(localized: "The passphrase does not open that key file.", comment: "Wrong passphrase for a picked key file")
        case .workFactorTooHigh:
            return String(localized: "That key file asks for more work than Sempere allows to open it.",
                          comment: "Picked key file has an scrypt work factor above the cap")
        case .postQuantumUnavailable:
            return String(localized: "This system cannot use post-quantum keys.", comment: "No ML-KEM on this OS")
        case .notAKey:
            return String(localized: "That is not an age key. Paste the secret key, AGE-SECRET-KEY-PQ-1…, or choose a key file.",
                          comment: "Existing key input is not recognized")
        }
    }
}
