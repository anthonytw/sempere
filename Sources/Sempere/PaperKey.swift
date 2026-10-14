import Crypto
import Foundation

/// Splits a secret (an `AGE-SECRET-KEY-1…` line, or an armored age file) into
/// numbered lines for a printed recovery kit, each with a short checksum
/// that stock tools can recompute:
///
/// ```
/// printf '%s' 'LINE' | sha256sum | cut -c1-4
/// ```
///
/// The age key already ends in a Bech32 checksum that catches any typo in
/// the whole key; the per-line checksums say *which* line holds it.
public enum PaperKey {
    /// One printed line.
    public struct Line: Hashable, Sendable {
        /// 1-based line number.
        public var number: Int
        /// The characters to type, exactly (no spaces added).
        public var text: String
        /// `text` split into groups for reading aloud or copying; joining
        /// the groups gives `text`.
        public var groups: [String]
        /// First 4 hex digits of SHA-256(`text`).
        public var checksum: String
    }

    /// First 4 lowercase hex digits of SHA-256 of the UTF-8 bytes of `text`.
    public static func checksum(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(2).map { b in
            let s = String(b, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    /// Prefixes of the two age identity types, longest first: the post-quantum
    /// hybrid (`age-keygen -pq`, 77 characters) and X25519 (74 characters).
    static let identityPrefixes = ["AGE-SECRET-KEY-PQ-1", "AGE-SECRET-KEY-1"]

    /// First `digits` lowercase hex digits of SHA-256 of the UTF-8 bytes of
    /// `text`. A post-quantum public key is 1959 characters, too long to print
    /// or compare by eye; its fingerprint identifies it
    /// (`age-keygen -y key.txt | tr -d '\n' | sha256sum | cut -c1-16`).
    public static func fingerprint(_ text: String, digits: Int = 16) -> String {
        let hex = SHA256.hash(data: Data(text.utf8)).map { b in
            let s = String(b, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
        return String(hex.prefix(max(0, min(digits, hex.count))))
    }

    /// The lines of an age identity: the fixed `AGE-SECRET-KEY-1` or `AGE-SECRET-KEY-PQ-1` prefix,
    /// then the Bech32 data and checksum in lines of `perLine` characters,
    /// grouped by 5.
    public static func identityLines(_ identity: String, perLine: Int = 20) -> [Line] {
        let key = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        var texts: [String] = []
        var rest = Substring(key)
        let prefix = identityPrefixes.first { key.hasPrefix($0) }
        if let prefix {
            texts.append(prefix)
            rest = rest.dropFirst(prefix.count)
        }
        while !rest.isEmpty {
            texts.append(String(rest.prefix(perLine)))
            rest = rest.dropFirst(perLine)
        }
        return texts.enumerated().map { i, t in
            Line(number: i + 1, text: t, groups: i == 0 && t == prefix ? [t] : group(t, by: 5),
                 checksum: checksum(t))
        }
    }

    /// The lines of a text file (an armored age file): one per line, as is.
    public static func textLines(_ text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
            .enumerated()
            .map { i, t in Line(number: i + 1, text: t, groups: [t], checksum: checksum(t)) }
    }

    static func group(_ s: String, by n: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            out.append(String(rest.prefix(n)))
            rest = rest.dropFirst(n)
        }
        return out
    }
}
