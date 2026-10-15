import Foundation

/// `vault.json`, the plaintext manifest (format.md §2).
public struct VaultManifest: Hashable, Sendable, Codable {
    /// One entry of `recipients`.
    public struct Recipient: Hashable, Sendable, Codable {
        /// Bech32 `age1...` X25519 recipient.
        public var key: String
        /// Free-form, e.g. "Anthony's iPad".
        public var label: String
        /// When the recipient was added.
        public var added: Date

        /// - Parameters:
        ///   - key: Bech32 `age1...` recipient (not validated here; `Vault`
        ///     validates when reading or writing).
        ///   - label: free-form display name.
        ///   - added: when it was added.
        public init(key: String, label: String, added: Date) {
            self.key = key; self.label = label; self.added = added
        }

        /// The longest label writers store, in characters.
        public static let maxLabelLength = 80

        /// A label as `Vault` stores it: one line (line breaks become
        /// spaces), trimmed, at most `maxLabelLength` characters. It may be
        /// empty (format.md §2.1's repair writes empty labels).
        public static func cleanLabel(_ label: String) -> String {
            let oneLine = label.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(oneLine.prefix(maxLabelLength))
        }

        /// A label as readers show it: `cleanLabel` (another writer may
        /// have stored any text), "Device" when empty.
        public static func displayLabel(_ label: String) -> String {
            let clean = cleanLabel(label)
            return clean.isEmpty ? "Device" : clean
        }

        /// `displayLabel(label)`.
        public var displayLabel: String { Self.displayLabel(label) }
    }

    /// `sempere/1`.
    public var format: String
    /// Random per vault; lowercase on the wire.
    public var vaultId: UUID
    /// When the vault was created.
    public var created: Date
    /// At least one.
    public var recipients: [Recipient]
    /// The 32-byte vault secret, age-encrypted (armored) to exactly `recipients`.
    public var vaultSecret: String
    /// Format extensions the vault uses (format.md §2), e.g. `attachments`.
    /// Empty when absent; written only when non-empty.
    public var features: [String]
    /// `recipientsTag` (format.md §2.1): lowercase hex HMAC over `vaultId`
    /// and the recipient keys under a key derived from the vault secret. Nil
    /// when absent; a value that is not a string reads as `""` (a tag that
    /// never verifies), so a hostile file cannot make the manifest unreadable.
    public var recipientsTag: String?
    /// `secretLink` (format.md §2.1): proof, signed by the outgoing secret's
    /// keys, that the last secret rotation was made by a holder of the old
    /// secret. A value of another shape reads as `.malformed` (a link that
    /// never verifies, which writers drop).
    public var secretLink: SecretLink?
    /// `markersTag` (format.md §2.1 "Version markers"): lowercase hex HMAC
    /// over `vaultId`, `format` and `features` under a key derived from the
    /// vault secret. Read leniently, like `recipientsTag`.
    public var markersTag: String?
    /// `rewrapPending` (format.md §3.3.1 "Binding the journal"): lowercase hex
    /// HMAC over `vaultId` and the SHA-256 of `rewrap-journal.json`'s bytes,
    /// under a key derived from the (new) vault secret; present only while a
    /// recipient change is unfinished. Read leniently, like
    /// `recipientsTag`.
    public var rewrapPending: String?
    /// `label` (format.md §2): the vault's name for display (in a WebDAV vault
    /// list, where the folder may be called anything). Informational and not
    /// authenticated, like a recipient's label: readers show it cleaned
    /// (`displayLabel`) and never act on it. Nil when absent, empty or not a string.
    public var label: String?

    /// `label` as readers show it: one line, trimmed, at most
    /// `Recipient.maxLabelLength` characters; nil when there is none.
    public var displayLabel: String? { Self.cleanVaultLabel(label) }

    /// A vault label as writers store and readers show it: `Recipient.cleanLabel`
    /// with control characters turned into spaces (it is printed to terminals)
    /// and invisible format characters removed (Unicode Cf: bidi overrides,
    /// isolates and marks, zero-width characters), so a server cannot reorder
    /// or hide what a vault list shows; nil when empty.
    public static func cleanVaultLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        var scalars = String.UnicodeScalarView()
        for u in label.unicodeScalars {
            switch u.properties.generalCategory {
            case .control: scalars.append(" ")
            case .format: continue
            default: scalars.append(u)
            }
        }
        let clean = Recipient.cleanLabel(String(scalars))
        return clean.isEmpty ? nil : clean
    }

    /// `label` alone, from `vault.json` bytes that need not decode as a whole
    /// manifest (a server's, read without the key), cleaned; nil when there is none.
    public static func peekLabel(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return cleanVaultLabel(obj["label"] as? String)
    }

    /// The extensions this implementation knows: none (format.md §2). A
    /// later version names its extensions here; a writer must not write to a
    /// vault that uses any it does not know (§7.3).
    public static let knownFeatures: Set<String> = []

    /// Builds a manifest value. No validation happens here; `Vault.create`
    /// and `Vault.open` enforce format.md §2.
    ///
    /// - Parameters:
    ///   - format: `sempere/1` unless testing other versions.
    ///   - vaultSecret: the armored age file holding the 32-byte secret.
    public init(format: String = SempereFormat.identifier, vaultId: UUID, created: Date, recipients: [Recipient],
                vaultSecret: String, features: [String] = [], recipientsTag: String? = nil, secretLink: SecretLink? = nil,
                markersTag: String? = nil, rewrapPending: String? = nil, label: String? = nil) {
        self.format = format; self.vaultId = vaultId; self.created = created
        self.recipients = recipients; self.vaultSecret = vaultSecret; self.features = features
        self.recipientsTag = recipientsTag; self.secretLink = secretLink; self.markersTag = markersTag
        self.rewrapPending = rewrapPending
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case format, vaultId, created, recipients, vaultSecret, features, recipientsTag, secretLink, markersTag, rewrapPending
        case label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        vaultId = try c.decode(LowercaseUUID.self, forKey: .vaultId).uuid
        created = try c.decode(Date.self, forKey: .created)
        recipients = try c.decode([Recipient].self, forKey: .recipients)
        vaultSecret = try c.decode(String.self, forKey: .vaultSecret)
        features = try c.decodeIfPresent([String].self, forKey: .features) ?? []
        recipientsTag = Self.lenientString(c, .recipientsTag)
        markersTag = Self.lenientString(c, .markersTag)
        rewrapPending = Self.lenientString(c, .rewrapPending)
        label = Self.cleanVaultLabel(try? c.decodeIfPresent(String.self, forKey: .label))
        // SecretLink's decoder never throws: any shape but null reads as one.
        secretLink = (try? c.decodeNil(forKey: .secretLink)) == false ? try? c.decode(SecretLink.self, forKey: .secretLink) : nil
    }

    /// Nil when absent (or JSON null), the string when it is one, else `""`.
    private static func lenientString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        guard c.contains(key), (try? c.decodeNil(forKey: key)) != true else { return nil }
        return (try? c.decode(String.self, forKey: key)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(LowercaseUUID(vaultId), forKey: .vaultId)
        try c.encode(created, forKey: .created)
        try c.encode(recipients, forKey: .recipients)
        try c.encode(vaultSecret, forKey: .vaultSecret)
        if !features.isEmpty { try c.encode(features, forKey: .features) }
        try c.encodeIfPresent(recipientsTag, forKey: .recipientsTag)
        if let secretLink, secretLink != .malformed { try c.encode(secretLink, forKey: .secretLink) }
        try c.encodeIfPresent(markersTag, forKey: .markersTag)
        try c.encodeIfPresent(rewrapPending, forKey: .rewrapPending)
        try c.encodeIfPresent(Self.cleanVaultLabel(label), forKey: .label)
    }

    /// The features this implementation does not know, sorted.
    public var unknownFeatures: [String] {
        Set(features).subtracting(Self.knownFeatures).sorted()
    }

    /// The manifest as written to disk: InkJSON conventions, pretty-printed
    /// because this is the one plaintext file people read, newline-terminated.
    public func encoded() throws -> Data {
        let e = InkJSON.encoder()
        e.outputFormatting.insert(.prettyPrinted)
        return try e.encode(self) + Data("\n".utf8)
    }

    /// `format` alone, from bytes that may not decode as a whole manifest.
    static func peekFormat(_ data: Data) -> String? {
        struct Format: Decodable { var format: String }
        return try? JSONDecoder().decode(Format.self, from: data).format
    }

    /// Parses `vault.json` bytes.
    public static func decode(_ data: Data) throws -> VaultManifest {
        try InkJSON.decoder().decode(VaultManifest.self, from: data)
    }
}

extension VaultManifest {
    /// Whether two `vault.json` files are the same vault: the same bytes, or
    /// manifests that differ only in the display `label` (format.md §1.3: it
    /// is covered by no tag, §2). Compared as JSON objects without `label`,
    /// so a difference in any other member, unknown ones included, counts.
    public static func sameExceptLabel(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard (try? decode(a)) != nil, (try? decode(b)) != nil,
              var x = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any],
              var y = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] else { return false }
        x["label"] = nil
        y["label"] = nil
        // Canonical JSON (sorted keys at every level), so member order and spacing do not count.
        guard let cx = try? JSONSerialization.data(withJSONObject: x, options: [.sortedKeys]),
              let cy = try? JSONSerialization.data(withJSONObject: y, options: [.sortedKeys]) else { return false }
        return cx == cy
    }
}
