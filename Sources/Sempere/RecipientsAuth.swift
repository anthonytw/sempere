import Crypto
import Foundation

// Authenticated recipients (format.md §2.1).
//
// `vault.json` is plaintext, and every writer encrypts to the keys it lists.
// `recipientsTag` authenticates those keys under a key derived from the vault
// secret, and `secretLink` authenticates a secret rotation under the outgoing
// secret, so that a forged `vault.json` carrying a secret of the attacker's
// own (and a tag that verifies under it) is caught by every device that knew
// the real one. Each device keeps a `RecipientsTrustRecord` outside the vault.

/// The keys, tags and checks of format.md §2.1.
public enum RecipientsAuth {
    static let recipientsInfo = "sempere/1 recipients key"
    static let secretIdInfo = "sempere/1 secret id"

    /// The most entries deleted when looking for the last verified list
    /// inside a tampered one (format.md §2.1, §9).
    public static let maxSearchDeletions = 3
    /// Lists longer than this are not searched: C(16, ≤3) = 696 HMACs over at
    /// most 16 post-quantum keys (about 32 KB each) is the bound on the work.
    public static let maxSearchKeys = 16

    static func derive(_ secret: VaultSecret, _ info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.key, info: Data(info.utf8), outputByteCount: 32)
    }

    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    /// `secretId` of a secret.
    static func secretId(_ secret: VaultSecret) -> Data { bytes(derive(secret, secretIdInfo)) }

    /// `"sempere/1" ‖ 0 ‖ "recipients" ‖ 0 ‖ vaultId (‖ 0 ‖ key)*`.
    static func tagMessage(vaultId: UUID, keys: [String]) -> Data {
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "recipients".utf8)
        m.append(0); m.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        for k in keys { m.append(0); m.append(contentsOf: k.utf8) }
        return m
    }

    /// The raw tag of `keys` (in order) under `secret`.
    static func tagBytes(vaultId: UUID, keys: [String], secret: VaultSecret) -> Data {
        tagBytes(vaultId: vaultId, keys: keys, key: derive(secret, recipientsInfo))
    }

    static func tagBytes(vaultId: UUID, keys: [String], key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: tagMessage(vaultId: vaultId, keys: keys), using: key))
    }

    /// `recipientsTag` (lowercase hex) of `keys`, in order, under `secret`.
    public static func tag(vaultId: UUID, keys: [String], secret: VaultSecret) -> String {
        Hex.encode(tagBytes(vaultId: vaultId, keys: keys, secret: secret))
    }

    /// True when `tag` is 64 lowercase hex digits and verifies over `keys`.
    public static func verifyTag(_ tag: String, vaultId: UUID, keys: [String], secret: VaultSecret) -> Bool {
        guard let given = Hex.decode(tag) else { return false }
        return constantTimeEqual(given, tagBytes(vaultId: vaultId, keys: keys, secret: secret))
    }

    /// Whether `secret` is the one `record` was saved for, or a confirmed
    /// successor of it (format.md §2.1 "Checking", step 3): nil when neither,
    /// else true for a rotation.
    ///
    /// A signed record (`sempere-trust/2`) holds public keys: the secret is
    /// the same when its keys are the record's, a successor when `link`'s
    /// two signatures verify under them. A legacy record (`sempere-trust/1`,
    /// an HMAC key) is read only to upgrade it: it confirms the same secret
    /// and nothing else, since whoever read it could forge a legacy link
    /// (security review 2026-10, R2).
    static func confirms(_ record: RecipientsTrustRecord, secret: VaultSecret, link: SecretLink?, vaultId: UUID) -> Bool? {
        switch record.anchor {
        case .signed(let keys):
            guard let mine = try? LinkPublicKeys(secret: secret) else { return nil }
            if mine == keys { return false }
            return verifyLink(link, keys: keys, to: secret, vaultId: vaultId) ? true : nil
        case .legacy(let linkKey):
            return constantTimeEqual(legacyLinkKey(secret), linkKey) ? false : nil
        }
    }

    /// The longest list obtained from `keys` by deleting at most
    /// `maxSearchDeletions` entries (order kept) whose tag is `tag` under
    /// `secret`, and the deleted entries; nil when none (or the list is
    /// longer than `maxSearchKeys`). Fewer deletions are tried first.
    static func verifiedSubset(of keys: [String], tag: String, vaultId: UUID,
                               secret: VaultSecret) -> (kept: [String], deleted: [String])? {
        guard keys.count <= maxSearchKeys, let given = Hex.decode(tag) else { return nil }
        let key = derive(secret, recipientsInfo)
        var result: (kept: [String], deleted: [String])?
        func search(_ deletions: Int, from start: Int, removed: [Int]) {
            guard result == nil else { return }
            if deletions == 0 {
                let drop = Set(removed)
                let kept = keys.indices.filter { !drop.contains($0) }.map { keys[$0] }
                guard !kept.isEmpty else { return }
                if constantTimeEqual(given, tagBytes(vaultId: vaultId, keys: kept, key: key)) {
                    result = (kept, removed.map { keys[$0] })
                }
                return
            }
            guard start < keys.count else { return }
            for i in start..<keys.count { search(deletions - 1, from: i + 1, removed: removed + [i]) }
        }
        for d in 1...maxSearchDeletions where d < keys.count {
            search(d, from: 0, removed: [])
            if result != nil { break }
        }
        return result
    }

    /// Classifies `manifest`'s list (format.md §2.1 "Checking") for a reader
    /// holding `secret`, with this device's trust record (ignored when it is
    /// another vault's).
    public static func evaluate(_ manifest: VaultManifest, secret: VaultSecret,
                                record: RecipientsTrustRecord?) -> RecipientsStatus {
        let record = record?.vaultId == manifest.vaultId ? record : nil
        let keys = manifest.recipients.map(\.key)
        let id = manifest.vaultId
        // Whether the secret is one this device verified (or a confirmed
        // successor of it) is decided first, whatever the tag says: a tag
        // that is missing or does not verify is otherwise judged under a
        // secret the attacker may have chosen, and the subset search below
        // would hand the attacker's own key to a repair as "last verified"
        // (security review 2026-10, R1, R3).
        var rotated = false
        if let record {
            guard let rotation = confirms(record, secret: secret, link: manifest.secretLink, vaultId: id) else {
                // Unconfirmed, even when every key is one this device trusted:
                // a secret this device cannot link to one it verified may be an
                // attacker's, and accepting it would let a later `secretLink`
                // made under it vouch for any list. No repair: the files are
                // tagged under a secret this device no longer holds (format.md
                // §2.1 "Repair").
                return .tampered(.init(reason: .secretUnconfirmed, current: keys, restore: nil, record: record))
            }
            rotated = rotation
        }
        guard let tag = manifest.recipientsTag else {
            let featured = manifest.features.contains(VaultManifest.recipientsTagFeature)
            guard featured || record != nil else {
                // An untagged list whose markers were tagged (or say they were) is still checked.
                if let reason = markersProblem(manifest, secret: secret, record: nil) {
                    return .tampered(.init(reason: reason, unexpected: [], missing: [], restore: nil))
                }
                return .untagged
            }
            return .tampered(.init(reason: .tagRemoved, current: keys, restore: record?.recipients, record: record))
        }
        guard verifyTag(tag, vaultId: id, keys: keys, secret: secret) else {
            if let found = verifiedSubset(of: keys, tag: tag, vaultId: id, secret: secret) {
                return .tampered(.init(reason: .tagMismatch, current: keys, restore: found.kept, record: record))
            }
            return .tampered(.init(reason: .tagMismatch, current: keys, restore: record?.recipients, record: record))
        }
        if let reason = markersProblem(manifest, secret: secret, record: record) {
            return .tampered(.init(reason: reason, unexpected: [], missing: [], restore: nil))
        }
        guard record != nil else { return .verified(.firstUse) }
        return .verified(rotated ? .rotated : .unchanged)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

/// How a reader classified `vault.json`'s recipients (format.md §2.1).
public enum RecipientsStatus: Hashable, Sendable {
    /// The vault is locked: nothing was checked.
    case notChecked
    /// No tag and no sign there ever was one: written before §2.1. Writers
    /// upgrade it (`Vault.upgradeRecipientsTag`).
    case untagged
    /// The tag verifies, and the secret is the one this device knew (or a
    /// confirmed successor of it).
    case verified(Verification)
    /// Refused for writing (`VaultError.untrustedRecipients`).
    case tampered(RecipientsProblem)

    /// Why a list counts as verified.
    public enum Verification: String, Hashable, Sendable, Codable {
        /// Same secret as this device's trust record.
        case unchanged
        /// No trust record yet: first use on this device.
        case firstUse
        /// The secret rotated and `secretLink` verifies under the record.
        case rotated
    }

    /// True when writers may encrypt to the list: verified or untagged.
    public var allowsWriting: Bool {
        switch self {
        case .tampered: return false
        case .notChecked, .untagged, .verified: return true
        }
    }

    /// The problem, when tampered.
    public var problem: RecipientsProblem? {
        if case .tampered(let p) = self { return p }
        return nil
    }

    /// `verified`, `untagged`, `tampered` or `not-checked`, for reports.
    public var name: String {
        switch self {
        case .notChecked: return "not-checked"
        case .untagged: return "untagged"
        case .verified: return "verified"
        case .tampered: return "tampered"
        }
    }
}

/// A recipients list refused for writing (format.md §2.1).
public struct RecipientsProblem: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable, Codable {
        /// `recipientsTag` does not verify (or is malformed).
        case tagMismatch
        /// The tag was removed from a vault that had one (a downgrade).
        case tagRemoved
        /// The secret changed without a `secretLink` this device can check
        /// (whatever keys the list holds).
        case secretUnconfirmed
        /// This device's trust record for the vault exists but cannot be
        /// read (damaged, tampered with, or a newer record format): nothing
        /// can be compared, so the list is not trusted for writing until the
        /// user confirms it (security review 2026-10, R5).
        case recordUnreadable
        /// `markersTag` does not verify (or is malformed): `format` or
        /// `features` were changed without the vault's key (format.md §2.1
        /// "Version markers"; security review 2026-10, N3).
        case markersMismatch
        /// The markers tag was removed from a vault that had one (its feature
        /// is listed, or this device's record holds its markers): a downgrade.
        case markersRemoved
        /// The markers verify but name a lower major or fewer features than
        /// this device last verified: an older `vault.json` put back.
        case markersRolledBack
    }

    public var reason: Reason
    /// Keys listed now that are not in the last verified list (this device's
    /// record when there is no other); when no list is known, every listed
    /// key (none can be confirmed).
    public var unexpected: [String]
    /// Keys of the last verified list that are no longer listed.
    public var missing: [String]
    /// The last verified list, which a repair writes; nil when this device
    /// cannot tell it, or (`secretUnconfirmed`) when no repair is possible.
    public var restore: [String]?

    init(reason: Reason, current: [String], restore: [String]?, record: RecipientsTrustRecord?) {
        self.reason = reason
        let restore = restore.flatMap { $0.isEmpty ? nil : $0 }
        self.restore = restore
        if let known = restore ?? record?.recipients {
            let keep = Set(known)
            unexpected = current.filter { !keep.contains($0) }
        } else {
            unexpected = current
        }
        let now = Set(current)
        var missing = (restore ?? []).filter { !now.contains($0) }
        for k in record?.recipients ?? [] where !now.contains(k) && !missing.contains(k) { missing.append(k) }
        self.missing = missing
    }

    public init(reason: Reason, unexpected: [String], missing: [String], restore: [String]?) {
        self.reason = reason; self.unexpected = unexpected; self.missing = missing; self.restore = restore
    }
}

/// What a device remembers about a vault's recipients (format.md §2.1
/// "Trust record"): never stored in the vault. A current record
/// (`sempere-trust/2`) holds only public keys, which check a `secretLink`
/// but cannot make one.
public struct RecipientsTrustRecord: Codable, Hashable, Sendable {
    /// The current record format.
    public static let formatName = "sempere-trust/2"
    /// Records written before signed links: an HMAC `linkKey`. Read only to
    /// upgrade them (format.md §2.1), never written.
    public static let legacyFormatName = "sempere-trust/1"

    /// What identifies the last verified secret.
    public enum Anchor: Hashable, Sendable {
        /// The secret's link verification keys (`sempere-trust/2`).
        case signed(LinkPublicKeys)
        /// The secret's legacy HMAC `linkKey` (`sempere-trust/1`, 32 bytes).
        case legacy(Data)
    }

    public var vaultId: UUID
    /// The last verified secret.
    public var anchor: Anchor
    /// The keys of the last verified list, in order.
    public var recipients: [String]
    /// The version markers last verified (format.md §2.1 "Version markers");
    /// nil when the vault's markers were not tagged then (or the record is
    /// older than them).
    public var markers: VaultMarkers?
    /// True once this device saw the record's secret with no rotation into it
    /// pending (format.md §3.3.1 "Finished rotations"): no rewrap journal is
    /// accepted from then on whose previous secret is not this one. Only ever
    /// set while the record names the same secret; never on a legacy record.
    public var rewrapFinished: Bool

    /// `sempere-trust/2`, or `sempere-trust/1` for a legacy record.
    public var format: String {
        if case .legacy = anchor { return Self.legacyFormatName }
        return Self.formatName
    }

    /// True for a `sempere-trust/1` record, which the next write replaces.
    public var isLegacy: Bool { if case .legacy = anchor { return true }; return false }

    public init(vaultId: UUID, anchor: Anchor, recipients: [String], markers: VaultMarkers? = nil,
                rewrapFinished: Bool = false) {
        self.vaultId = vaultId; self.anchor = anchor; self.recipients = recipients; self.markers = markers
        self.rewrapFinished = rewrapFinished
    }

    /// The record for a list verified under `secret`.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    public init(vaultId: UUID, secret: VaultSecret, recipients: [String], markers: VaultMarkers? = nil,
                rewrapFinished: Bool = false) throws {
        self.init(vaultId: vaultId, anchor: .signed(try LinkPublicKeys(secret: secret)), recipients: recipients,
                  markers: markers, rewrapFinished: rewrapFinished)
    }

    /// True when the record names `secret` (its link public keys) and says the
    /// rotation into it finished (format.md §3.3.1 rule 3).
    func saysRewrapFinished(for secret: VaultSecret) -> Bool {
        guard rewrapFinished, case .signed(let keys) = anchor, let mine = try? LinkPublicKeys(secret: secret) else {
            return false
        }
        return mine == keys
    }

    enum CodingKeys: String, CodingKey { case format, vaultId, linkKey, linkPublicKeys, recipients, markers, rewrapFinished }
    enum KeyCodingKeys: String, CodingKey { case ed25519, mldsa65 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(String.self, forKey: .format)
        vaultId = try c.decode(LowercaseUUID.self, forKey: .vaultId).uuid
        switch format {
        case Self.formatName:
            let k = try c.nestedContainer(keyedBy: KeyCodingKeys.self, forKey: .linkPublicKeys)
            guard let ed = Hex.decode(try k.decode(String.self, forKey: .ed25519), count: LinkPublicKeys.ed25519Size),
                  let ml = Hex.decode(try k.decode(String.self, forKey: .mldsa65), count: LinkPublicKeys.mldsa65Size),
                  let keys = LinkPublicKeys(ed25519: ed, mldsa65: ml) else {
                throw DecodingError.dataCorruptedError(forKey: .linkPublicKeys, in: c,
                                                       debugDescription: "not 32 + 1952 bytes of lowercase hex")
            }
            anchor = .signed(keys)
        case Self.legacyFormatName:
            guard let key = Hex.decode(try c.decode(String.self, forKey: .linkKey)) else {
                throw DecodingError.dataCorruptedError(forKey: .linkKey, in: c, debugDescription: "not 64 hex digits")
            }
            anchor = .legacy(key)
        default:
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "not \(Self.formatName)")
        }
        recipients = try c.decode([String].self, forKey: .recipients)
        markers = try c.decodeIfPresent(VaultMarkers.self, forKey: .markers).map { VaultMarkers(format: $0.format, features: $0.features) }
        // Only a signed record carries it (a legacy one is replaced at the next write).
        rewrapFinished = format == Self.formatName ? (try c.decodeIfPresent(Bool.self, forKey: .rewrapFinished) ?? false) : false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(LowercaseUUID(vaultId), forKey: .vaultId)
        switch anchor {
        case .signed(let keys):
            var k = c.nestedContainer(keyedBy: KeyCodingKeys.self, forKey: .linkPublicKeys)
            try k.encode(Hex.encode(keys.ed25519), forKey: .ed25519)
            try k.encode(Hex.encode(keys.mldsa65), forKey: .mldsa65)
        case .legacy(let key):
            try c.encode(Hex.encode(key), forKey: .linkKey)
        }
        try c.encode(recipients, forKey: .recipients)
        try c.encodeIfPresent(markers, forKey: .markers)
        if rewrapFinished, !isLegacy { try c.encode(true, forKey: .rewrapFinished) }
    }
}

/// Where a device keeps its trust records.
public protocol RecipientsTrustStore: Sendable {
    /// The record of `vaultId`, nil when there is none.
    ///
    /// - Throws: when a record exists but cannot be read or does not decode
    ///   (or names another vault). Never nil for that: a record that reads as
    ///   absent would make the next open a first use, and the next write
    ///   would replace it (format.md §2.1, security review 2026-10, R5).
    func record(for vaultId: UUID) throws -> RecipientsTrustRecord?
    /// Saves (replaces) the record of its vault.
    func save(_ record: RecipientsTrustRecord) throws
}

/// Trust records as files `<directory>/<vaultId>.json` (mode 0600).
public struct FileRecipientsTrustStore: RecipientsTrustStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The largest record file read.
    static let maxFileBytes = 1 << 20

    /// `$XDG_STATE_HOME/sempere/trust`, else `~/.local/state/sempere/trust`.
    public static func cliDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        DeviceState.defaultURL(environment: environment, home: home).deletingLastPathComponent()
            .appendingPathComponent("trust", isDirectory: true)
    }

    func fileURL(_ vaultId: UUID) -> URL {
        directory.appendingPathComponent("\(vaultId.uuidString.lowercased()).json")
    }

    public func record(for vaultId: UUID) throws -> RecipientsTrustRecord? {
        let url = fileURL(vaultId)
        // Absent only when nothing is there at all (not even a dangling link).
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return nil }
        let r: RecipientsTrustRecord
        do {
            let data = try BoundedRead.contents(of: url, maxBytes: Self.maxFileBytes)
            r = try JSONDecoder().decode(RecipientsTrustRecord.self, from: data)
        } catch {
            throw VaultError.io("trust record \(url.path) is unreadable: \(error)")
        }
        guard r.vaultId == vaultId else {
            throw VaultError.io("trust record \(url.path) names another vault")
        }
        return r
    }

    /// Writes the record atomically, created mode 0600 in a 0700 folder. A
    /// current record holds only public keys; it stays private anyway: it
    /// names the vault and its devices, and a legacy record it replaces held
    /// an HMAC key that could make a link (security review 2026-10, R2).
    public func save(_ record: RecipientsTrustRecord) throws {
        try FileIO.createDirectory(directory)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(record)
        let url = fileURL(record.vaultId)
        let tmp = FileIO.tempURL(in: directory)
        try FileIO.writeNewFile(tmp) { write in try write(data) }
        guard rename(tmp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw VaultError.io("rename to \(url.path): errno \(code)")
        }
    }
}

/// Trust records in memory (tests, and readers that keep none on disk).
public final class MemoryRecipientsTrustStore: RecipientsTrustStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: RecipientsTrustRecord] = [:]
    private var unreadable: [UUID: String] = [:]

    public init() {}

    public func record(for vaultId: UUID) throws -> RecipientsTrustRecord? {
        lock.lock(); defer { lock.unlock() }
        if let why = unreadable[vaultId] { throw VaultError.io("trust record unreadable: \(why)") }
        return records[vaultId]
    }

    public func save(_ record: RecipientsTrustRecord) throws {
        lock.lock(); defer { lock.unlock() }
        unreadable[record.vaultId] = nil
        records[record.vaultId] = record
    }

    /// Makes the record of `vaultId` read as unreadable (`why`) until the
    /// next `save`: a damaged file, for tests and dry runs.
    public func markUnreadable(_ vaultId: UUID, _ why: String) {
        lock.lock(); defer { lock.unlock() }
        records[vaultId] = nil
        unreadable[vaultId] = why
    }

    /// Forgets every record.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        records = [:]
        unreadable = [:]
    }
}

extension Vault {
    /// Whether a `vault.json` received from elsewhere (a sync server) may
    /// replace the local one (format.md §2.1): nil when it may, else why not.
    ///
    /// It may when it is `local`'s list, tag and secret, or when `vault` is
    /// unlocked and the incoming list verifies: its
    /// tag under the secret it carries, and that secret is the local one or
    /// a confirmed successor (`secretLink`). The anchor is this device's
    /// trust record when it has one, else the local vault's own secret and
    /// list. Without a key a changed list cannot be checked and is refused;
    /// the same keys under another tag are taken (nobody new can read, and
    /// the next unlock checks the tag).
    ///
    /// - Parameters:
    ///   - data: the incoming bytes.
    ///   - local: the local `vault.json` bytes; nil on a first pull (accepted).
    ///   - vault: the local vault, opened with identities if possible.
    public static func incomingManifestProblem(_ data: Data, local: Data?, vault: Vault?) -> String? {
        let incoming: VaultManifest
        do { incoming = try readManifest(data) } catch { return "the incoming vault.json does not parse: \(error)" }
        guard let local else { return nil }
        guard let mine = try? readManifest(local) else { return nil }   // a damaged local copy: take the remote one
        guard incoming.vaultId == mine.vaultId else { return "the incoming vault.json belongs to another vault" }
        // Under one secret and list, `rewrapPending` only ever goes away (format.md
        // §3.3.1 step 4; a change of the list may bind a new journal): one that
        // comes back, or changes, is a vault.json put back to replay a finished
        // change's journal (security review 2026-10, S4). The same sealed secret
        // means the same list.
        let pendingBack = incoming.rewrapPending != nil && incoming.rewrapPending != mine.rewrapPending
        let pendingProblem = "the incoming vault.json brings back a finished recipient change (rewrapPending under the "
            + "same secret, format.md §3.3.1): an older copy put back"
        if pendingBack, incoming.vaultSecret == mine.vaultSecret { return pendingProblem }
        let sameKeys = incoming.recipients.map(\.key) == mine.recipients.map(\.key)
        let sameMarkers = incoming.format == mine.format && incoming.features == mine.features
            && incoming.markersTag == mine.markersTag
        if sameKeys, sameMarkers, incoming.recipientsTag == mine.recipientsTag, incoming.vaultSecret == mine.vaultSecret {
            return nil
        }
        guard let vault, vault.canRead, vault.vaultId == mine.vaultId else {
            // Without the key only public fields can be compared: the same
            // keys and the same sealed secret let nobody new read, and a tag
            // may only be added. Anything else waits: a new secret under the
            // same keys (or a changed tag) cannot be checked here, and taking
            // it would replace the vault's real secret with one the server
            // chose (security review 2026-10, W3).
            guard sameKeys else {
                return "the incoming vault.json changes the device list; unlock (--identity) so it can be checked (format.md §2.1)"
            }
            guard incoming.vaultSecret == mine.vaultSecret else {
                return "the incoming vault.json changes the vault's secret; unlock (--identity) so it can be checked (format.md §2.1)"
            }
            if let tag = mine.recipientsTag, incoming.recipientsTag != tag {
                return incoming.recipientsTag == nil
                    ? "the incoming vault.json drops the device list's tag (format.md §2.1); unlock (--identity) to check it"
                    : "the incoming vault.json changes the device list's tag; unlock (--identity) to check it (format.md §2.1)"
            }
            // Version markers (format.md §2.1, security review 2026-10, N3): once tagged
            // here they change only under a check; untagged ones may only grow (a
            // tag added, a higher major, more features), never be lowered.
            if mine.markersTag != nil || mine.features.contains(VaultManifest.markersTagFeature) {
                guard sameMarkers else {
                    return "the incoming vault.json changes the vault's format or features; unlock (--identity) to check it (format.md §2.1)"
                }
            } else if !VaultMarkers(mine).isCovered(by: incoming) {
                return "the incoming vault.json names an older format or fewer features than the local one (format.md §2.1)"
            }
            return nil
        }
        if !VaultMarkers(mine).isCovered(by: incoming) {
            return "the incoming vault.json names an older format or fewer features than the local one (format.md §2.1)"
        }
        let secret: VaultSecret
        do { secret = try decryptSecret(incoming.vaultSecret, with: vault.identities) } catch {
            return "the incoming vault.json's secret does not open with this key: \(error)"
        }
        if pendingBack, sameKeys, let own = try? decryptSecret(mine.vaultSecret, with: vault.identities),
           RecipientsAuth.constantTimeEqual(own.bytes, secret.bytes) {
            return pendingProblem
        }
        var anchor: RecipientsTrustRecord?
        do { anchor = try vault.trustStore?.record(for: vault.vaultId) } catch {
            return "this device's trust record for the vault cannot be read, so the incoming vault.json cannot be checked: \(error)"
        }
        if anchor == nil, vault.recipientsStatus.allowsWriting, let own = vault.secret {
            anchor = try? RecipientsTrustRecord(vaultId: vault.vaultId, secret: own, recipients: vault.recipients.map(\.key),
                                                markers: mine.markersTag != nil ? VaultMarkers(mine) : nil)
        }
        switch RecipientsAuth.evaluate(incoming, secret: secret, record: anchor) {
        case .verified, .notChecked: return nil
        case .untagged:
            return sameKeys ? nil : "the incoming vault.json changes the device list without a tag (format.md §2.1)"
        case .tampered(let p): return "the incoming vault.json was not written with the vault's key: \(p.description)"
        }
    }
}
