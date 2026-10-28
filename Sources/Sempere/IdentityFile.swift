import Age
import Foundation

/// Errors reading `age-keygen` style identity text.
public enum IdentityFileError: Error, Hashable, Sendable {
    /// No `AGE-SECRET-KEY-…` line, or one that does not parse.
    case malformed
    /// The `# public key:` comment names another key than the secret key.
    case mismatch(String)
}

/// The `age-keygen` style identity text (format.md §3.1):
///
/// ```
/// # created: 2026-10-04T16:20:00Z
/// # public key: age1pq1...
/// AGE-SECRET-KEY-PQ-1...
/// ```
///
/// The recovery key (the kit) is one, and a device key file (`DeviceKeys`) reads as one. `parse` also
/// reads a classic X25519 identity (`AGE-SECRET-KEY-1...`), so that it can be refused with a clear
/// error (`VaultError.classicIdentity`).
public enum IdentityFile {
    /// Readers accept scrypt work factors up to 20 by default (format.md §15.11).
    public static let defaultMaxWorkFactor = 20
    /// The largest cap a reader may choose ("may accept up to 22").
    public static let maxAllowedWorkFactor = 22

    /// The name the app suggests when it saves or shares a plaintext key file (`render`'s text):
    /// `Sempere key - <label>.txt`. The label is cut to one line of at most 60 characters, without path
    /// separators or control characters; an empty one gives `Sempere key.txt`.
    public static func exportFileName(label: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = String(String.UnicodeScalarView(label.unicodeScalars.map { banned.contains($0) ? " " : $0 }))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Sempere key.txt" : "Sempere key - \(name).txt"
    }

    /// The plaintext, `age-keygen` style, newline-terminated.
    public static func render(_ identity: NativeIdentity, created: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return "# created: \(f.string(from: created))\n# public key: \(identity.recipient.string)\n\(identity.string)\n"
    }

    /// Parses `age-keygen` style text: the first line that is neither blank nor a `#` comment must be
    /// the identity. A `# public key:` comment, if present, must match it.
    ///
    /// - Throws: `IdentityFileError`, or `AgeError.postQuantumUnavailable` for a post-quantum identity
    ///   on a platform without ML-KEM.
    public static func parse(_ text: String) throws -> NativeIdentity {
        var declared: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let prefix = "# public key:"
                if line.hasPrefix(prefix) {
                    declared = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            let id: NativeIdentity
            do { id = try NativeIdentity(string: line) } catch AgeError.postQuantumUnavailable {
                throw AgeError.postQuantumUnavailable
            } catch { throw IdentityFileError.malformed }
            if let declared, declared != id.recipient.string { throw IdentityFileError.mismatch(declared) }
            return id
        }
        throw IdentityFileError.malformed
    }
}
