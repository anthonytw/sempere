import Age
import Crypto
import Foundation

// `vault.json` versions of other epochs met on a sync target (docs/design/key-hierarchy.md §4.3, §5.5, §5.6;
// format.md §15.10, §15.15; phase KH4). A device judges each one against what it verified, from local files
// only (the engine pulls `epochs/` first, so a new epoch's record is usually local by then):
//
// - a later epoch it verifies and the precedence rule follows (a removal, a handoff, a kit replacement, a
//   takeover, also one whose number is lower than its own): **taken**, and its own files caught up;
// - a direct child of its pinned epoch whose record has not arrived, linked and signed from the pinned epoch:
//   **taken**, with files under the older key pending until the record arrives (§4.3 step 2);
// - a later epoch it cannot verify yet: **unverified-pending**. It keeps its own `vault.json`, keeps writing
//   locally, uploads nothing new (J5b) and pulls again; the version is remembered as a **sighting** in the
//   device's trust store, so every target and every later run hold back too;
// - a later epoch it verifies whose kept chain does not list it: **unlisted** (§5.5). It never pins it, keeps
//   its own `vault.json`, writes nothing (`VaultError.removedFromVault`), stops uploading and keeps pulling;
//   a takeover that re-admits it undoes that;
// - its own chain is the later one (an ancestor epoch, a branch a takeover dropped, an older version): kept,
//   and its own may replace the target's.

/// A `vault.json` of another epoch that this device saw on a sync target and did not take (design §4.3
/// "unverified-pending", §5.5): kept in the device's trust store (format.md §15.10 "Sightings").
public struct EpochSighting: Hashable, Sendable {
    /// The `vault.json` bytes as seen.
    public var manifest: Data
    /// Where it was seen (a target's location, for the status line).
    public var source: String
    /// When it was first seen.
    public var seen: Date
    /// Its epoch and id, from the file (plaintext).
    public var epoch: Int
    public var epochId: Data

    public init(manifest: Data, source: String, seen: Date = Date()) throws {
        let m = try Vault.readManifest(manifest)
        self.manifest = manifest; self.source = SyncTextClean.line(source, max: 200); self.seen = seen
        epoch = m.epoch; epochId = m.epochId
    }

    /// The largest sightings file read.
    static let maxFileBytes = 8 << 20
    /// At most this many are kept per vault (the newest epochs); a further one replaces the oldest.
    public static let maxCount = 8

    private struct Wire: Codable {
        var source: String
        var seen: String
        var manifest: String
    }

    private struct File: Codable {
        var format: String
        var vaultId: String
        var sightings: [Wire]
    }

    static let format = "sempere-sightings/1"

    static func encodeFile(_ sightings: [EpochSighting], vaultId: UUID) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(File(format: format, vaultId: vaultId.uuidString.lowercased(), sightings: sightings.map {
            Wire(source: $0.source, seen: RFC3339.string($0.seen), manifest: $0.manifest.base64EncodedString())
        }))
    }

    static func decodeFile(_ data: Data, vaultId: UUID) throws -> [EpochSighting] {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.format == format, file.vaultId == vaultId.uuidString.lowercased() else {
            throw VaultError.io("not the sightings of this vault")
        }
        return try file.sightings.prefix(maxCount).map { w in
            guard let bytes = Data(base64Encoded: w.manifest), bytes.count <= BoundedRead.maxManifestBytes else {
                throw VaultError.io("a sighting's vault.json does not decode")
            }
            return try EpochSighting(manifest: bytes, source: w.source, seen: RFC3339.parse(w.seen) ?? Date())
        }
    }
}

/// Printable, bounded text for names that come from elsewhere.
enum SyncTextClean {
    static func line(_ s: String, max: Int) -> String {
        String(s.unicodeScalars.map { $0.properties.generalCategory == .control ? "?" : Character($0) }.prefix(max))
    }
}

/// How this device judges a `vault.json` met elsewhere (a sync target) against its own (design §4.3, §5.1,
/// §5.5, §5.6). Only a vault opened with a device key judges epochs; see `Vault.judgeIncoming`.
public enum IncomingEpoch: Hashable, Sendable {
    /// The same file, or one differing only in the unauthenticated `label`.
    case same
    /// A later version of this epoch by its home, or a later epoch this device verified and follows: take it.
    case later
    /// A direct child of this device's pinned epoch, linked and signed from it, whose record has not arrived:
    /// take it; files under the older key stay pending until the record arrives (design §4.3 step 2).
    case laterRecordPending
    /// This device's own is the later one (an older version of this epoch, an ancestor epoch, a branch the
    /// precedence rule drops): keep it; it may replace the other.
    case behind
    /// A later epoch this device cannot verify yet (its record has not arrived, or the vault is locked here):
    /// keep this device's, upload nothing new until it is verified (design §4.3 "unverified-pending", J5b).
    case waiting(String)
    /// A later epoch this device verified, whose kept chain does not list it (design §5.5).
    case unlisted(String)
    /// Versions that are not one writer's (a home conflict, lists that do not contain each other): both
    /// kept, never merged.
    case conflict(String)
    /// It does not check (tampered, another vault): never taken.
    case refused(String)

    /// True for `later` and `laterRecordPending`.
    public var isTaken: Bool {
        switch self {
        case .later, .laterRecordPending: return true
        default: return false
        }
    }
}

extension Vault {
    // MARK: - Judging (design §4.3)

    /// Judges `data`, a `vault.json` met elsewhere, against this vault's own (design §4.3, §5.6). Reads local
    /// files only (`epochs/` for the incoming epoch's record). A vault opened locked or with the recovery key
    /// judges only what needs no key: the same epoch (`same`, or `waiting` for a change it cannot check) and a
    /// later epoch number (`waiting`); anything else is `conflict`.
    ///
    /// - Parameter local: the local `vault.json` bytes, when the caller has them (a label-only difference is
    ///   then `same`).
    public func judgeIncoming(_ data: Data, local: Data? = nil) -> IncomingEpoch {
        let incoming: EpochManifest
        do { incoming = try Self.readManifest(data) } catch { return .refused("it does not parse: \(error)") }
        guard incoming.vaultId == vaultId else { return .refused("it belongs to another vault") }
        guard incoming.root == manifest.root else { return .refused("it has another root: not this vault") }
        if let local, EpochManifest.sameExceptLabel(data, local) { return .same }
        if incoming.epochId == manifest.epochId {
            var a = incoming, b = manifest
            a.label = nil; b.label = nil
            if a == b { return .same }
            guard canRead else { return .waiting("it changes the device list; unlock this vault so it can be checked") }
            if isLaterVersion(incoming, of: manifest) { return .later }
            if isLaterVersion(manifest, of: incoming) { return .behind }
            return .conflict("it is not a later version of this one by the home device (design §5.1): both are kept")
        }
        guard canRead, case .device = openedWith else {
            if incoming.epoch >= manifest.epoch {
                return .waiting("it is of another epoch (\(incoming.epoch)); unlock this vault with a device key to check it")
            }
            return .conflict("it is of an earlier epoch (\(incoming.epoch)); unlock this vault with a device key to check it")
        }
        let ours = ownChain()
        if ours.ids.contains(incoming.epochId) { return .behind }
        // A child of a pinned epoch is checked against it before anything else, with or without its record: one
        // whose link or signatures do not verify is refused, never waited for (a forged vault.json whose record
        // is missing would otherwise hold every device back).
        if pinnedParentRefuses(incoming) {
            return .refused("it claims to follow epoch \(incoming.epoch - 1) but is not linked and signed as that epoch requires")
        }
        if Self.epochMutations.contains(.takeoverByArrival), incoming.epochReason == EpochReason.takeover.rawValue,
           manifest.epochReason == EpochReason.takeover.rawValue {
            return .behind
        }
        let held = identityRecipients
        guard let entry = incoming.devices.first(where: { held.contains($0.key) }) else {
            if let notice = Self.removalNotice(incoming, held: held, signing: signing, trust: trustStore)
                ?? takeoverWithoutThisDevice(incoming) {
                // Verified from the pinned epoch (link and signatures): unlisted, unless this device's own chain
                // drops it (a takeover that re-admitted this device, design §5.6).
                if let node = manifestNode(incoming),
                   Self.keptChain(extra: [node], ours: ours, pinned: trustedRecord()?.chain ?? []) == ours.ids {
                    return .behind
                }
                return .unlisted(notice)
            }
            // Not verifiable from here (its parent is not pinned: a fork further back). At this device's epoch or
            // later it may be the branch that dropped this device: it holds this device back (J5b), unless its
            // signed fields already lose to this device's own chain.
            if incoming.epoch >= manifest.epoch {
                if incoming.epoch == manifest.epoch, let node = manifestNode(incoming),
                   Self.keptChain(extra: [node], ours: ours, pinned: trustedRecord()?.chain ?? []) == ours.ids {
                    return .behind
                }
                return .waiting("epoch \(incoming.epoch) does not list this device and cannot be verified from here")
            }
            return .conflict("epoch \(incoming.epoch) does not list this device and is not on its chain")
        }
        let key: VaultEpochKey
        do { key = try EpochKeyWrap.open(entry.wrap, with: unlockIdentities, vaultId: vaultId, epoch: incoming.epoch) } catch {
            return .refused("this device's wrap in it does not open to a key of its epoch (tampered)")
        }
        let record = Self.readCurrentRecord(url, manifest: incoming, key: key)
        if case .problem(let p) = record, p.reason == .otherEpoch {
            // The record has not arrived: a direct child of the pinned epoch is taken; anything else waits.
            if let trusted = trustedRecord(), trusted.pinned?.epochId == manifest.epochId,
               Self.recordPendingCheck(incoming, key: key, trusted: trusted) != nil {
                return .laterRecordPending
            }
            return .waiting("waiting for the device-change record \(incoming.epochRecord) of epoch \(incoming.epoch)")
        }
        let check = Self.listCheck(incoming, key: key, trust: trustStore, root: givenRoot, record: record)
        guard let chain = check.chain else {
            if check.pinnable != nil || check.status.problem?.reason == .otherEpoch {
                return .waiting(check.status.problem?.detail ?? "it cannot be verified yet")
            }
            return .refused(check.status.problem?.detail ?? "it does not check")
        }
        switch Self.precedence(incoming: chain, ours: ours, pinned: trustedRecord()?.chain ?? []) {
        case .incoming:
            if case .refused(let p) = check.status, p.reason != .otherEpoch { return .refused(p.detail) }
            return .later
        case .ours:
            return .behind
        case .neither(let why):
            return .conflict(why)
        }
    }

    /// True when `m`'s parent is an epoch of this device's pinned chain and `m` does not verify from it (its link
    /// under the parent's link keys, and its signatures: by the parent's home, or for a takeover by the kit the
    /// takeover rule names and its new home). False when it verifies, or its parent is not pinned here.
    func pinnedParentRefuses(_ m: EpochManifest) -> Bool {
        guard let record = trustedRecord(), let parent = m.parent,
              let c = record.chain.first(where: { $0.epochId == parent }) else { return false }
        let frontier = EpochFrontier(vaultId: record.vaultId, root: record.root, epoch: c.epoch, epochId: c.epochId,
                                     linkPublicKeys: c.linkPublicKeys, recovery: c.recovery, home: c.home)
        if frontier.verifiedChild(m) != nil { return false }
        return !takeoverVerifiesFromPinned(m, record: record)
    }

    /// This device's trust record of this vault, nil when it has none or it cannot be read.
    func trustedRecord() -> EpochTrustRecord? {
        guard let trustStore else { return nil }
        return (try? trustStore.record(for: vaultId)) ?? nil
    }

    /// Pins the verified prefix of `data`'s chain when it is a takeover by a kit this device has not pinned
    /// yet (design §5.6 rule 3, `ListCheck.pinnable`): the next judgment then takes it. Returns true when
    /// it pinned something.
    @discardableResult
    public func pinDeferredTakeover(_ data: Data) -> Bool {
        guard canRead, case .device = openedWith, trustStore != nil, let incoming = try? Self.readManifest(data),
              incoming.vaultId == vaultId, let entry = incoming.devices.first(where: { identityRecipients.contains($0.key) }),
              let key = try? EpochKeyWrap.open(entry.wrap, with: unlockIdentities, vaultId: vaultId, epoch: incoming.epoch) else {
            return false
        }
        let check = Self.listCheck(incoming, key: key, trust: trustStore, root: givenRoot,
                                   record: Self.readCurrentRecord(url, manifest: incoming, key: key))
        guard let pinnable = check.pinnable else { return false }
        var copy = self
        copy.pinnable = pinnable
        copy.manifest = incoming
        return (try? copy.pinDeferredPrefix()) != nil
    }

    /// This vault's own chain: the verified chain of its record, or (epoch 1, or a direct child whose record
    /// has not arrived) the pinned chain and this epoch built from `vault.json`.
    func ownChain() -> (ids: [Data], nodes: [EpochNode]) {
        if let verifiedChain { return (verifiedChain.entries.map(\.epochId), Self.nodes(verifiedChain)) }
        let pinned = trustedRecord()?.chain ?? []
        var nodes: [EpochNode] = []
        var homeOf: [Data: Data] = [:]
        for c in pinned { homeOf[c.epochId] = c.home }
        for c in pinned { if let n = Self.node(c, parentHome: c.parent.flatMap { homeOf[$0] }) { nodes.append(n) } }
        var ids = pinned.map(\.epochId)
        if !ids.contains(manifest.epochId), let reason = EpochReason(rawValue: manifest.epochReason),
           let recovery = manifest.recoveryFingerprint {
            let signer = (reason == .takeover || reason == .create) ? manifest.home : (manifest.parent.flatMap { homeOf[$0] } ?? manifest.home)
            nodes.append(EpochNode(epochId: manifest.epochId, parent: manifest.parent, signer: signer, reason: reason,
                                   home: manifest.home, list: Set(manifest.firstList), recovery: recovery,
                                   recoverySigner: reason == .takeover ? recovery : nil))
            ids.append(manifest.epochId)
        }
        if ids.isEmpty { ids = [manifest.epochId] }
        return (ids, nodes)
    }

    /// A takeover under an epoch of this device's pinned chain (not only its frontier) that does not list it,
    /// verified from the pinned chain alone (design §5.6 rule 3): the link under that epoch's link keys,
    /// `recoverySig` by the kit `TakeoverRule` names for this device, `epochSig` by the new home. Why, or nil.
    func takeoverWithoutThisDevice(_ m: EpochManifest) -> String? {
        // A direct child of the frontier is `removalNotice`'s (the shared `EpochFrontier.verifiedChild`); this covers
        // a takeover under an older pinned epoch.
        guard let record = trustedRecord(), m.parent != record.pinned?.epochId, takeoverVerifiesFromPinned(m, record: record),
              let home = m.homeEntry
        else { return nil }
        return "this device is not on the newest device list of the vault: \(DeviceName.display(home.name)) (\(home.id ?? "?")) "
            + "took over with the recovery kit (epoch \(m.epoch)). It writes nothing to the vault. If that is a mistake, a "
            + "takeover with the recovery kit undoes it, and this device rejoins when the vault shows it."
    }

    /// `m` is a takeover whose parent is pinned here, verified from the trust record alone: its link, `recoverySig`
    /// by the kit `TakeoverRule` names, `epochSig` by its new home.
    func takeoverVerifiesFromPinned(_ m: EpochManifest, record: EpochTrustRecord) -> Bool {
        guard EpochReason(rawValue: m.epochReason) == .takeover,
              let i = record.chain.firstIndex(where: { $0.epochId == m.parent }), m.epoch == record.chain[i].epoch + 1,
              EpochLinks.verify(m.epochLink, keys: record.chain[i].linkPublicKeys, epoch: m.epoch, childEpochId: m.epochId,
                                vaultId: m.vaultId),
              let message = m.epochMessage, let rs = m.recoverySig, let recovery = m.recoveryEntry, let rk = recovery.sign,
              TakeoverRule.recoveryKey(parentRecovery: record.chain[i].recovery, parentPath: record.chain[...i].map(\.epochId),
                                       pinned: record.chain.map { TakeoverRule.PinnedEpoch(epochId: $0.epochId, recovery: $0.recovery) })
                == recovery.fingerprint,
              rs.verifies(message, keys: rk), let home = m.homeEntry, let hk = home.sign, m.epochSig.verifies(message, keys: hk)
        else { return false }
        return true
    }

    /// The precedence rule's view of a `vault.json` whose record this device cannot read, from its own signed
    /// fields: its signer is its parent's home as the pinned chain gives it (a takeover: its new home).
    func manifestNode(_ m: EpochManifest) -> EpochNode? {
        guard let reason = EpochReason(rawValue: m.epochReason), let recovery = m.recoveryFingerprint else { return nil }
        let pinned = trustedRecord()?.chain ?? []
        let parentHome = pinned.first { $0.epochId == m.parent }?.home
        let signer = (reason == .takeover || reason == .create) ? m.home : (parentHome ?? m.home)
        return EpochNode(epochId: m.epochId, parent: m.parent, signer: signer, reason: reason, home: m.home,
                         list: Set(m.firstList), recovery: recovery, recoverySigner: reason == .takeover ? recovery : nil)
    }

    /// The kept chain of the precedence rule over the pinned chain, this device's own chain and `extra`.
    static func keptChain(extra: [EpochNode], ours: (ids: [Data], nodes: [EpochNode]),
                          pinned: [EpochTrustRecord.ChainEpoch]) -> [Data]? {
        var byId: [Data: EpochNode] = [:]
        var homeOf: [Data: Data] = [:]
        for c in pinned { homeOf[c.epochId] = c.home }
        for c in pinned { if let n = node(c, parentHome: c.parent.flatMap { homeOf[$0] }) { byId[n.epochId] = n } }
        for n in ours.nodes { byId[n.epochId] = n }
        for n in extra { byId[n.epochId] = n }
        return (try? EpochPrecedence.resolve(Array(byId.values), pinned: pinned.map(\.epochId),
                                             mutations: precedenceMutations))?.keptChain
    }

    enum PrecedenceOutcome {
        case incoming
        case ours
        case neither(String)
    }

    /// The precedence rule (design §5.6) over the pinned chain, this device's own chain and an incoming
    /// verified chain: which of the two it keeps.
    static func precedence(incoming chain: EpochChain.Verified, ours: (ids: [Data], nodes: [EpochNode]),
                           pinned: [EpochTrustRecord.ChainEpoch]) -> PrecedenceOutcome {
        var byId: [Data: EpochNode] = [:]
        var homeOf: [Data: Data] = [:]
        for c in pinned { homeOf[c.epochId] = c.home }
        for c in pinned { if let n = node(c, parentHome: c.parent.flatMap { homeOf[$0] }) { byId[n.epochId] = n } }
        for n in ours.nodes { byId[n.epochId] = n }
        for n in nodes(chain) { byId[n.epochId] = n }
        let incomingIds = chain.entries.map(\.epochId)
        guard let result = try? EpochPrecedence.resolve(Array(byId.values), pinned: pinned.map(\.epochId),
                                                        mutations: precedenceMutations) else {
            return .neither("the two chains do not meet at epoch 1")
        }
        if result.keptChain == incomingIds { return .incoming }
        if result.keptChain == ours.ids { return .ours }
        if !result.homeConflicts.isEmpty {
            return .neither("a home conflict: the home device signed two changes under one epoch (design §5.6); "
                + "this device stays where it is until a takeover settles it")
        }
        return .neither("the precedence rule keeps neither chain")
    }

    /// The checks of a direct child of the pinned epoch whose record has not arrived (design §4.3 step 2):
    /// the link under the pinned epoch's link keys, `epochSig` by the pinned home (a takeover: by its new
    /// home, and `recoverySig` by the pinned kit), a first list within the pinned list, and every check of
    /// `EpochManifest.check` against the pinned epoch as this device verified it. Returns the entries
    /// admitted, nil when it fails.
    static func recordPendingCheck(_ m: EpochManifest, key: VaultEpochKey, trusted record: EpochTrustRecord) -> [EpochKeyEntry]? {
        // The shared "believe this next epoch" predicate first (link, signer, kit), then every check under the key.
        guard let pinned = record.pinned, let frontier = EpochFrontier(record: record), frontier.verifiedChild(m) != nil
        else { return nil }
        let list = Set(record.list.map(\.fingerprint))
        let ancestry = record.chain.reduce(into: list) { $0.formUnion($1.list) }
        let parent = EpochManifest.VerifiedParent(list: list, home: record.home, recovery: pinned.recovery, ancestry: ancestry)
        guard let admitted = try? m.check(key: key, verifiedList: Set(m.firstList), parent: parent, mutations: precedenceMutations),
              record.markers.isCovered(by: m) else { return nil }
        return admitted
    }

    /// True when `data` is the approval of a joining device that holds one of `identities` (design §6.2 step 3):
    /// the same vault and root as the local `vault.json` (`local`), which lists none of the keys, while `data`
    /// lists one and its wrap opens to a key of its epoch. Taking it pins nothing: the device confirms the vault
    /// with the reply words (`confirmJoin`), and writes nothing until then.
    public static func isJoinApproval(_ data: Data, local: Data, identities: [any AgeIdentity]) -> Bool {
        guard !identities.isEmpty, let incoming = try? readManifest(data), let mine = try? readManifest(local),
              incoming.vaultId == mine.vaultId, incoming.root == mine.root else { return false }
        let held = Set(identities.compactMap(recipientString))
        guard !mine.keys.contains(where: { held.contains($0.key) }),
              let entry = incoming.devices.first(where: { held.contains($0.key) }) else { return false }
        return (try? EpochKeyWrap.open(entry.wrap, with: identities, vaultId: incoming.vaultId, epoch: incoming.epoch)) != nil
    }

    // MARK: - Sightings (design §4.3, §5.5)

    /// The sightings of this vault in the device's trust store (none without one).
    public func sightings() -> [EpochSighting] {
        (try? trustStore?.sightings(for: vaultId)) ?? []
    }

    /// Remembers `data` (a `vault.json` this device did not take, `waiting` or `unlisted`) as seen at
    /// `source`, so every later run and target holds back too. The same epoch is remembered once; at most
    /// `EpochSighting.maxCount` are kept (the newest epochs).
    public func rememberSighting(_ data: Data, source: String, now: Date = Date()) throws {
        guard let trustStore else { return }
        let s = try EpochSighting(manifest: data, source: source, seen: now)
        var all = try trustStore.sightings(for: vaultId)
        if let i = all.firstIndex(where: { $0.epochId == s.epochId }) {
            if all[i].manifest == data { return }
            all[i].manifest = data
        } else {
            all.append(s)
        }
        all.sort { ($0.epoch, $0.seen) < ($1.epoch, $1.seen) }
        if all.count > EpochSighting.maxCount { all.removeFirst(all.count - EpochSighting.maxCount) }
        try trustStore.saveSightings(all, for: vaultId)
    }

    /// What this device's sightings say now (design §4.3, §5.5), each judged again against this vault: the
    /// ones that are no longer of interest (`same`, `behind`, `refused`) are forgotten, and the rest returned
    /// with their judgment. A sighting that is now `later` (its record arrived from another target) is for
    /// the caller to take, then forget (`forgetSighting`).
    @discardableResult
    public func settleSightings() -> [(sighting: EpochSighting, judgment: IncomingEpoch)] {
        guard let trustStore, canRead, case .device = openedWith, let all = try? trustStore.sightings(for: vaultId),
              !all.isEmpty else { return [] }
        var kept: [EpochSighting] = []
        var out: [(EpochSighting, IncomingEpoch)] = []
        for s in all {
            let j = judgeIncoming(s.manifest)
            switch j {
            case .same, .behind, .refused: continue
            default:
                kept.append(s)
                out.append((s, j))
            }
        }
        if kept != all { try? trustStore.saveSightings(kept, for: vaultId) }
        return out
    }

    /// Forgets the sighting of epoch `epochId` (it was taken).
    public func forgetSighting(_ epochId: Data) {
        guard let trustStore, var all = try? trustStore.sightings(for: vaultId) else { return }
        let before = all.count
        all.removeAll { $0.epochId == epochId }
        if all.count != before { try? trustStore.saveSightings(all, for: vaultId) }
    }

    /// Why this device is unlisted, or waits for a later epoch, from its sightings (judged at open).
    func sightingNotices() -> (unlisted: String?, waiting: String?) {
        var unlisted: String?, waiting: String?
        for s in sightings() where s.epochId != manifest.epochId {
            switch judgeIncoming(s.manifest) {
            case .unlisted(let n): unlisted = unlisted ?? n
            case .waiting(let why): waiting = waiting ?? "\(why) (seen at \(s.source))"
            default: break
            }
        }
        return (unlisted, waiting)
    }
}
