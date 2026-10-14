import Foundation

extension Vault {
    /// The vault's display name (format.md §2 `label`), cleaned; nil when it has none.
    public var label: String? { manifest.displayLabel }

    /// Sets or clears (nil or empty) the vault's display name in `vault.json`
    /// (format.md §2 `label`). The rest of the file is written back as it is,
    /// tagged as every write of it is.
    ///
    /// - Throws: what `requireWritable` throws (a tampered device list, a
    ///   newer format), `locked` without the key, and `manifestCorrupt` when
    ///   `vault.json` changed since the vault was opened: other keys or secret,
    ///   markers that do not check, or a newer format or features.
    public mutating func setLabel(_ label: String?) throws {
        try requireWritable()
        let secret = try requireSecret()
        var m = try Self.readManifest(FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))
        // As `clearRewrapPending`: never re-tag markers that do not check (that would launder a
        // change made without the key), and never rewrite a vault.json a newer version wrote since.
        guard m.recipients.map(\.key) == manifest.recipients.map(\.key), m.vaultSecret == manifest.vaultSecret,
              m.rewrapPending == manifest.rewrapPending, m.markersIntact(secret: secret),
              Self.readOnlyReasons(m).isEmpty else {
            throw VaultError.manifestCorrupt(VaultError.changedSinceOpened)
        }
        let wanted = VaultManifest.cleanVaultLabel(label)
        guard m.label != wanted else { return }   // nothing to write
        m.label = wanted
        manifest = try Self.writeManifest(m, to: manifestURL, replacing: true, secret: secret)
    }
}
