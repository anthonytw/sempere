/// Vault layout, keys, body framing, revisions, merge, snapshots, compaction.
/// Normative spec: docs/format.md.
public enum SempereFormat {
    public static let identifier = "sempere/1"
    /// The label that starts every keyed hash (body tag, blob names). It names
    /// the framing, not the vault's `format`, so it stays `sempere/1` in a vault
    /// of a later major (format.md §4, §7.6).
    public static let tagLabel = "sempere/1"
    public static let bodyMagic: [UInt8] = Array("SMPR".utf8)
    public static let bodyVersion: UInt8 = 1
}
