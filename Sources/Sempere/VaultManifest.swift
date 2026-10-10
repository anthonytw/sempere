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
    /// never verifies, which writers drop); a string is a legacy HMAC link.
    public var secretLink: SecretLink?
    /// `markersTag` (format.md §2.1 "Version markers"): lowercase hex HMAC
    /// over `vaultId`, `format` and `features` under a key derived from the
    /// vault secret. Read leniently, like `recipientsTag`.
    public var markersTag: String?

    /// The extensions this implementation knows. A writer must not write to
    /// a vault that uses any other (format.md §2).
    public static let knownFeatures: Set<String> = [attachmentsFeature, recipientsTagFeature, signedLinkFeature,
                                                           markersTagFeature]
    /// Added before the first blob or attachment op is written (format.md §2, §8).
    public static let attachmentsFeature = "attachments"
    /// The vault carries `recipientsTag` (format.md §2.1). Older writers do
    /// not know it, so they stop writing instead of encrypting to an
    /// unchecked list or dropping the tag.
    public static let recipientsTagFeature = "recipients-tag"
    /// `secretLink` is signed (format.md §2.1), never a legacy HMAC. Older
    /// writers do not know it, so they stop writing instead of rotating the
    /// secret with a link that devices holding signed trust records refuse.
    public static let signedLinkFeature = "signed-secret-link"
    /// The vault carries `markersTag` (format.md §2.1 "Version markers").
    /// Older writers do not know it, so they stop writing instead of
    /// rewriting `vault.json` without the tag.
    public static let markersTagFeature = "markers-tag"

    /// Builds a manifest value. No validation happens here; `Vault.create`
    /// and `Vault.open` enforce format.md §2.
    ///
    /// - Parameters:
    ///   - format: `sempere/1` unless testing other versions.
    ///   - vaultSecret: the armored age file holding the 32-byte secret.
    public init(format: String = SempereFormat.identifier, vaultId: UUID, created: Date, recipients: [Recipient],
                vaultSecret: String, features: [String] = [], recipientsTag: String? = nil, secretLink: SecretLink? = nil,
                markersTag: String? = nil) {
        self.format = format; self.vaultId = vaultId; self.created = created
        self.recipients = recipients; self.vaultSecret = vaultSecret; self.features = features
        self.recipientsTag = recipientsTag; self.secretLink = secretLink; self.markersTag = markersTag
    }

    enum CodingKeys: String, CodingKey { case format, vaultId, created, recipients, vaultSecret, features, recipientsTag, secretLink, markersTag }

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
