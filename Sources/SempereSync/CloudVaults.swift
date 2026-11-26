import Crypto
import Foundation
import Sempere

// MARK: - The vaults an Apple Account's iCloud (CloudKit) database holds (docs/design/1.4-cloudkit.md §8, §9)
//
// Open Vault ▸ From iCloud, the suggestion on a device that lacks a target, and `sempere cloudkit list` all ask the same
// question: which `sempere-<vault id>` zones does this account have, and what are the vaults called. The answer is read
// with two requests per zone at most (the zone list, then `vault.json`'s record), never a zone's whole feed. Everything
// the database returns is untrusted (format.md §9): the name is a bounded, printable label, and a zone whose
// `vault.json` is missing, not inline or not that vault's is listed without a name rather than believed.

/// One vault found in the signed-in account's iCloud (CloudKit) database.
public struct CloudVaultListing: Codable, Hashable, Sendable, Identifiable {
    /// The vault's id, lowercased (from the zone's name).
    public var vaultId: String
    /// `sempere-<vault id>`.
    public var zone: String
    /// The vault's label (format.md §2) or, when its `vault.json` could not be read, `Vault <first 8 of the id>`; printable
    /// and bounded.
    public var name: String
    /// True when the name is the vault's own label.
    public var named: Bool
    /// When the zone's `vault.json` was last saved (a device added or renamed, a label written): what tells two vaults of one
    /// name, or two unnamed ones, apart. Nil when that record could not be read (a zone with no vault in it).
    public var modified: Date?
    /// False when the zone holds no readable `vault.json` of its own: an empty or half-made zone, which only Delete from
    /// iCloud can clear (nothing can be opened from it).
    public var hasVault: Bool

    public var id: String { vaultId }

    public init(vaultId: String, zone: String, name: String, named: Bool, modified: Date? = nil, hasVault: Bool = true) {
        self.vaultId = vaultId; self.zone = zone; self.name = name; self.named = named
        self.modified = modified; self.hasVault = hasVault
    }

    private enum CodingKeys: String, CodingKey { case vaultId, zone, name, named, modified, hasVault }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vaultId = try c.decode(String.self, forKey: .vaultId)
        zone = try c.decode(String.self, forKey: .zone)
        name = try c.decode(String.self, forKey: .name)
        named = try c.decode(Bool.self, forKey: .named)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified)
        hasVault = try c.decodeIfPresent(Bool.self, forKey: .hasVault) ?? true
    }
}

/// Why a vault could not be copied out of iCloud.
public enum CloudVaultsError: Error, Equatable, LocalizedError {
    /// The zone's `vault.json` is another vault's (or unreadable): nothing was imported.
    case zoneHoldsAnotherVault

    public var errorDescription: String? { "this iCloud zone does not hold the vault its name says; nothing was copied" }
}

public enum CloudVaults {
    /// The most zones looked at (an account with more has some other use for its database).
    public static let maxZones = 500
    /// The longest name kept.
    public static let maxNameLength = 80

    /// The vault id a zone name carries; nil for any other zone.
    public static func vaultId(ofZone zone: String) -> String? {
        guard zone.hasPrefix("sempere-"), let id = UUID(uuidString: String(zone.dropFirst("sempere-".count))),
              CloudRecordNaming.zoneName(vaultId: id.uuidString) == zone else { return nil }
        return id.uuidString.lowercased()
    }

    /// The account's vaults, by name. A zone whose name cannot be read is still listed (with a short id).
    public static func list(store: any CloudRecordStore) throws -> [CloudVaultListing] {
        var out: [CloudVaultListing] = []
        for zone in try store.zones().sorted().prefix(maxZones) {
            guard let id = vaultId(ofZone: zone) else { continue }
            let found = (try? manifestRecord(store: store, zone: zone, vaultId: id)) ?? nil
            let shown = found.flatMap { VaultLabelText.peekLabel($0.bytes) }.map(display) ?? ""
            out.append(CloudVaultListing(vaultId: id, zone: zone, name: shown.isEmpty ? "Vault " + id.prefix(8) : shown,
                                         named: !shown.isEmpty, modified: found?.modified, hasVault: found != nil))
        }
        return out.sorted { ($0.name.lowercased(), $0.vaultId) < ($1.name.lowercased(), $1.vaultId) }
    }

    /// The label in the zone's `vault.json` record, when that record is inline, intact and the vault's own.
    static func label(store: any CloudRecordStore, zone: String, vaultId: String) throws -> String? {
        try manifestRecord(store: store, zone: zone, vaultId: vaultId).flatMap { VaultLabelText.peekLabel($0.bytes) }
    }

    /// The zone's `vault.json`: its bytes and when it was saved, when that record is inline, intact and the vault's own.
    static func manifestRecord(store: any CloudRecordStore, zone: String, vaultId: String) throws -> (bytes: Data, modified: Date?)? {
        let name = CloudRecordNaming.fileName([Vault.manifestName])
        guard let r = try store.fetch(zone: zone, name: name, payload: true), r.kind == .file, (r.fields.tomb ?? 0) == 0,
              r.fields.path == Vault.manifestName, (r.fields.schema ?? 0) == CloudSchema.current,
              let bytes = r.fields.bytes, bytes.count <= BoundedRead.maxManifestBytes,
              r.fields.sha256 == Data(SHA256.hash(data: bytes)),
              SyncEngine.manifestFields(bytes)?.vaultId == vaultId else { return nil }
        return (bytes, r.modified)
    }

    /// What the zone held at the target's last run: live files and their bytes, from the metadata mirror in the state
    /// folder (never the network); nil before a first run or when the mirror cannot be read.
    public static func mirrorSummary(stateURL: URL) -> (files: Int, bytes: Int64)? {
        let url = stateURL.deletingLastPathComponent().appendingPathComponent("cloudkit", isDirectory: true)
            .appendingPathComponent("mirror-2.txt")
        guard let data = try? BoundedRead.contents(of: url, maxBytes: 512 << 20),
              let mirror = try? CloudMirror.decode(data, maxRecords: SyncLimits.defaultMaxEntries) else { return nil }
        let live = mirror.files.values.filter { !$0.tomb }
        return (live.count, live.reduce(0) { $0 + $1.size })
    }

    static func display(_ label: String) -> String {
        let printable = SyncReport.printable(label).trimmingCharacters(in: .whitespacesAndNewlines)
        return printable.count > maxNameLength ? String(printable.prefix(maxNameLength - 1)) + "…" : printable
    }

    /// Copies the vault `vaultId` out of the account's database into the empty folder `folder` (a keyless two-way run, which
    /// pulls everything and uploads nothing), with the target's state beside it in `stateURL`'s folder. The folder is then a
    /// vault copy to import into the store; the target is added to the imported copy, whose first run finds nothing to do.
    /// - Throws: `CloudRecordError` (an account problem, a zone that is not there) or the engine's errors.
    @discardableResult
    public static func download(vaultId: UUID, store: any CloudRecordStore, into folder: URL, stateURL: URL,
                                expectedUser: String? = nil, options: SyncOptions = SyncOptions()) throws -> SyncReport {
        let remote = CloudTargetRun.remote(store: store, vaultId: vaultId, stateURL: stateURL, expectedUser: expectedUser)
        try FileIO.createPrivateDirectory(folder)
        let report = try CloudTargetRun.run(vaultFolder: folder, remote: remote, vault: nil, stateURL: stateURL, twoWay: true, options: options)
        // The engine's same-vault check skips an empty folder: a zone that holds another vault's files (a hostile or confused
        // account) must not be imported, or given a target, as this one.
        guard report.errors.isEmpty, report.stoppedEarly == nil else { return report }
        guard (try? Vault.open(at: folder).vaultId) == vaultId else { throw CloudVaultsError.zoneHoldsAnotherVault }
        return report
    }
}
