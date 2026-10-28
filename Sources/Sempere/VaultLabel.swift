import Foundation

/// Cleaning of the plaintext names `vault.json` carries: the vault's `label` and device names
/// (format.md §2, §15.3). Both are printed to terminals and shown in lists, so a server must not be able
/// to reorder or hide what they show.
public enum VaultLabelText {
    /// The longest vault label writers store, in characters.
    public static let maxLength = 80

    /// One line (line breaks and other control characters become spaces), invisible format characters
    /// removed (Unicode Cf: bidi overrides, isolates and marks, zero-width characters), trimmed. It may be
    /// empty.
    public static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            case .format: continue
            default: scalars.append(u)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A vault label as writers store it and readers show it: `clean`, at most `maxLength` characters;
    /// nil when empty.
    public static func cleanVaultLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let clean = String(clean(label).prefix(maxLength))
        return clean.isEmpty ? nil : clean
    }

    /// `label` alone, from `vault.json` bytes that need not decode as a whole manifest (a server's,
    /// read without a key), cleaned; nil when there is none.
    public static func peekLabel(_ data: Data) -> String? {
        guard data.count <= EpochManifest.maxBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return cleanVaultLabel(obj["label"] as? String)
    }
}

extension EpochManifest {
    /// `label` as readers show it; nil when there is none.
    public var displayLabel: String? { VaultLabelText.cleanVaultLabel(label) }

    /// Whether two `vault.json` files are the same vault version: the same bytes, or manifests that
    /// differ only in the display `label` (format.md §1.3: it is covered by no tag or signature).
    /// Compared as JSON objects without `label`, so a difference in any other member counts.
    public static func sameExceptLabel(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard (try? parse(a)) != nil, (try? parse(b)) != nil,
              var x = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any],
              var y = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] else { return false }
        x["label"] = nil
        y["label"] = nil
        guard let cx = try? JSONSerialization.data(withJSONObject: x, options: [.sortedKeys]),
              let cy = try? JSONSerialization.data(withJSONObject: y, options: [.sortedKeys]) else { return false }
        return cx == cy
    }

    /// The manifest as written to disk: pretty-printed (the one plaintext file people read), keys
    /// sorted, slashes unescaped, newline-terminated.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self) + Data("\n".utf8)
    }

    /// `format` alone, from bytes that may not decode as a whole manifest.
    static func peekFormat(_ data: Data) -> String? {
        struct Format: Decodable { var format: String }
        return try? JSONDecoder().decode(Format.self, from: data).format
    }

    /// The features this implementation does not know, sorted.
    public var unknownFeatures: [String] { Set(features).subtracting(Self.knownFeatures).sorted() }

    /// The extensions this implementation knows: none (format.md §2). A writer must not write to a vault
    /// that uses any it does not know (§7.3).
    public static let knownFeatures: Set<String> = []

    /// The device entries, in list order.
    public var devices: [EpochKeyEntry] { keys.filter { $0.role == .device } }
    /// The recovery entry (exactly one in a manifest that parsed).
    public var recoveryEntry: EpochKeyEntry? { keys.first { $0.role == .recovery } }
    /// The home device's entry.
    public var homeEntry: EpochKeyEntry? { keys.first { $0.role == .device && $0.fingerprint == home } }
}

extension Vault {
    /// The vault's display name (format.md §2 `label`), cleaned; nil when it has none.
    public var label: String? { manifest.displayLabel }

    /// Sets or clears (nil or empty) the vault's display name in `vault.json` (format.md §2 `label`).
    /// The label is covered by no tag or signature, so any listed device may change it: the rest of the
    /// file is written back as it is.
    ///
    /// - Throws: what `requireWritable` throws, and `manifestCorrupt` when `vault.json` changed since the
    ///   vault was opened.
    public mutating func setLabel(_ label: String?) throws {
        try requireWritable()
        var m = try requireUnchangedOnDisk()
        let wanted = VaultLabelText.cleanVaultLabel(label)
        guard m.label != wanted else { return }   // nothing to write
        m.label = wanted
        manifest = try Self.writeManifest(m, to: manifestURL, replacing: true)
    }
}
