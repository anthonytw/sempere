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
    /// The targets (their locations) that showed it when last looked at. A **detached** sighting (its parent is
    /// on no chain this device holds: nothing verifies it, anyone with storage write access can plant one) holds
    /// back only runs on these targets, and is forgotten once none of them shows it (review of #86, M3).
    public var sources: [String]
    /// The first of `sources`, for status lines.
    public var source: String { sources.first ?? "?" }
    /// True when the target at `location` showed it when last looked at.
    public func shown(at location: String) -> Bool { sources.contains(SyncTextClean.line(location, max: 200)) }
    /// When it was first seen.
    public var seen: Date
    /// Its epoch and id, from the file (plaintext).
    public var epoch: Int
    public var epochId: Data

    public init(manifest: Data, source: String, seen: Date = Date()) throws {
        let m = try Vault.readManifest(manifest)
        self.manifest = manifest; self.sources = [SyncTextClean.line(source, max: 200)]; self.seen = seen
        epoch = m.epoch; epochId = m.epochId
    }

    /// The largest sightings file read.
    static let maxFileBytes = 8 << 20
    /// At most this many are kept per vault (the newest epochs); a further one replaces the oldest.
    public static let maxCount = 8

    private struct Wire: Codable {
        var sources: [String]
        var seen: String
        var manifest: String
    }

    private struct File: Codable {
        var format: String
        var vaultId: String
        var sightings: [Wire]
    }

    static let format = "sempere-sightings/2"

    static func encodeFile(_ sightings: [EpochSighting], vaultId: UUID) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(File(format: format, vaultId: vaultId.uuidString.lowercased(), sightings: sightings.map {
            Wire(sources: $0.sources, seen: RFC3339.string($0.seen), manifest: $0.manifest.base64EncodedString())
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
            var s = try EpochSighting(manifest: bytes, source: w.sources.first ?? "?", seen: RFC3339.parse(w.seen) ?? Date())
            s.sources = Array(w.sources.prefix(16)).map { SyncTextClean.line($0, max: 200) }
            return s
        }
    }
}

/// Printable, bounded text for names that come from elsewhere.
enum SyncTextClean {
    static func line(_ s: String, max: Int) -> String {
        // Controls and format characters (bidi overrides among them) never reach a status line.
        String(s.unicodeScalars.map { [.control, .format].contains($0.properties.generalCategory) ? "?" : Character($0) }
            .prefix(max))
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
        if let parentEpoch = pinnedParentRefuses(incoming) {
            return .refused("it claims to follow epoch \(parentEpoch) but is not linked and signed as that epoch requires")
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

    /// The parent's epoch number when `m`'s parent is an epoch of this device's pinned chain and `m` does not verify
    /// from it (its link under the parent's link keys, and its signatures: by the parent's home, or for a takeover
    /// by the kit the takeover rule names and its new home). Nil when it verifies, or its parent is not pinned here.
    func pinnedParentRefuses(_ m: EpochManifest) -> Int? {
        guard let record = trustedRecord(), let parent = m.parent,
              let c = record.chain.first(where: { $0.epochId == parent }) else { return nil }
        let frontier = EpochFrontier(vaultId: record.vaultId, root: record.root, epoch: c.epoch, epochId: c.epochId,
                                     linkPublicKeys: c.linkPublicKeys, recovery: c.recovery, home: c.home)
        if frontier.verifiedChild(m) != nil || takeoverVerifiesFromPinned(m, record: record) { return nil }
        return c.epoch
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
    ///
    /// - Parameter unconfirmed: the device keeps no trust record of this vault yet (it has not confirmed a join).
    ///   Then a local copy that already lists one of the keys is replaced too: a fake approval storage planted
    ///   (its wrap needs only the public key a join request publishes) never confirms, and must not keep the real
    ///   one out (review of #86, S5).
    public static func isJoinApproval(_ data: Data, local: Data, identities: [any AgeIdentity], unconfirmed: Bool = false)
        -> Bool {
        guard !identities.isEmpty, data != local, let incoming = try? readManifest(data), let mine = try? readManifest(local),
              incoming.vaultId == mine.vaultId, incoming.root == mine.root else { return false }
        let held = Set(identities.compactMap(recipientString))
        guard unconfirmed || !mine.keys.contains(where: { held.contains($0.key) }),
              let entry = incoming.devices.first(where: { held.contains($0.key) }) else { return false }
        return (try? EpochKeyWrap.open(entry.wrap, with: identities, vaultId: incoming.vaultId, epoch: incoming.epoch)) != nil
    }

    // MARK: - Sightings (design §4.3, §5.5)

    /// The sightings of this vault in the device's trust store (none without one).
    public func sightings() -> [EpochSighting] {
        (try? trustStore?.sightings(for: vaultId)) ?? []
    }

    /// Remembers `data` (a `vault.json` this device did not take, `waiting` or `unlisted`) as seen at
    /// `source`. The same epoch is remembered once, with every target that showed it. At most
    /// `EpochSighting.maxCount` are kept: detached ones go first (oldest first), then the lowest epochs, so planted
    /// ones never push out a sighting a pinned epoch anchors.
    public func rememberSighting(_ data: Data, source: String, now: Date = Date()) throws {
        guard let trustStore else { return }
        let s = try EpochSighting(manifest: data, source: source, seen: now)
        var all = try trustStore.sightings(for: vaultId)
        if let i = all.firstIndex(where: { $0.epochId == s.epochId }) {
            let place = s.sources[0]
            if all[i].manifest == data, all[i].sources.contains(place) { return }
            all[i].manifest = data
            if !all[i].sources.contains(place) { all[i].sources = Array((all[i].sources + [place]).suffix(16)) }
        } else {
            all.append(s)
        }
        while all.count > EpochSighting.maxCount {
            if let i = all.indices.filter({ !isAnchoredSighting(all[$0]) }).min(by: { all[$0].seen < all[$1].seen }) {
                all.remove(at: i)
            } else {
                all.sort { ($0.epoch, $0.seen) < ($1.epoch, $1.seen) }
                all.removeFirst()
            }
        }
        all.sort { ($0.epoch, $0.seen) < ($1.epoch, $1.seen) }
        try trustStore.saveSightings(all, for: vaultId)
    }

    /// True when `s`'s parent is an epoch this device pinned or holds on its own chain: a real device change (its
    /// signatures check against that epoch, or it would be refused) whose record may be withheld. It holds every
    /// run back (J5b). Otherwise it is detached: see `EpochSighting.sources`.
    public func isAnchoredSighting(_ s: EpochSighting) -> Bool {
        guard let m = try? Self.readManifest(s.manifest), let parent = m.parent else { return false }
        // A child of a pinned epoch is refused unless it verifies from it (`pinnedParentRefuses`).
        if trustedRecord()?.chain.contains(where: { $0.epochId == parent }) == true { return true }
        // A child of the epoch this device follows with its record pending: its signatures must check against this
        // device's own verified vault.json of that epoch (the link needs the record); a forgery is detached (N1).
        guard canRead, case .device = openedWith, parent == manifest.epochId, listStatus.allowsWriting else { return false }
        return signedFromLocal(m)
    }

    /// `m`'s signatures check against this vault's `vault.json` (its parent): `epochSig` by its home, or for a
    /// takeover `recoverySig` by its recovery kit and `epochSig` by the new home. The link is not checked here.
    func signedFromLocal(_ m: EpochManifest) -> Bool {
        guard m.vaultId == vaultId, m.root == manifest.root, m.epoch == manifest.epoch + 1, let message = m.epochMessage
        else { return false }
        let signer: EpochKeyEntry?
        if EpochReason(rawValue: m.epochReason) == .takeover {
            guard let rs = m.recoverySig, let entry = m.recoveryEntry, let rk = entry.sign,
                  entry.fingerprint == manifest.recoveryEntry?.fingerprint, rs.verifies(message, keys: rk) else { return false }
            signer = m.homeEntry
        } else {
            signer = m.keys.first { $0.role == .device && $0.fingerprint == manifest.home }
        }
        guard let signer, let keys = signer.sign else { return false }
        return m.epochSig.verifies(message, keys: keys)
    }

    /// A target (`source`) showed `data` as its `vault.json` (nil: none): each detached sighting it no longer shows
    /// stops counting it, and one no target shows any more is forgotten (M3).
    public func noteTargetShows(_ data: Data?, at source: String) {
        guard let trustStore, var all = try? trustStore.sightings(for: vaultId), !all.isEmpty else { return }
        let place = SyncTextClean.line(source, max: 200)
        let shown = data.flatMap { try? Self.readManifest($0) }?.epochId
        let before = all
        all = all.compactMap { s in
            guard s.epochId != shown, s.sources.contains(place), !isAnchoredSighting(s) else { return s }
            var t = s
            t.sources.removeAll { $0 == place }
            return t.sources.isEmpty ? nil : t
        }
        if all != before { try? trustStore.saveSightings(all, for: vaultId) }
    }

    /// The SHA-256 of each earlier record of this vault's chain, by file name under `epochs/`, as the records
    /// above it bind them (format.md §15.6), as far as they can be read: a file under one of these names with other
    /// bytes is junk (review of #86, M1), so sync sets it aside and fetches the record again.
    public func boundRecordHashes() -> [String: Data] {
        var out: [String: Data] = [:]
        for o in keyring?.all() ?? [] {
            if let h = o.recordHash, o.epoch >= 2 { out[EpochRecord.fileName(epoch: o.epoch, epochId: o.epochId)] = h }
        }
        return out
    }

    /// A digest of every epoch key this vault holds now (the current one, the chain's as far as its records read,
    /// and the off-chain ones of its ledger): a file that waited for a key is worth fetching again once it moves.
    public var heldKeysDigest: String {
        var ids = [manifest.epochId] + (keyring?.all().map(\.epochId) ?? []) + (keyring?.offChainEpochs().map(\.epochId) ?? [])
        ids.sort { $0.lexicographicallyPrecedes($1) }
        var data = Data()
        for id in ids { data.append(id) }
        return String(Hex.encode(Data(SHA256.hash(data: data))).prefix(16))
    }

    /// The trust store this vault was opened with, if any.
    public var publicTrustStore: (any EpochTrustStore)? { trustStore }

    /// For a run that cannot judge (upload-only, or without the key; review of #86, S3): a sighting of an epoch
    /// above the local `vault.json`'s holds it back by number alone. An anchored one (its parent on the trust
    /// record's chain) holds every target, a detached one the targets that showed it. Nil: no hold.
    public static func sightingHoldByNumber(_ local: Data, store: (any EpochTrustStore)?, location: String)
        -> (why: String, seen: Date)? {
        guard let store, let m = try? readManifest(local),
              let all = try? store.sightings(for: m.vaultId), !all.isEmpty else { return nil }
        let pinned = Set(((try? store.record(for: m.vaultId)) ?? nil)?.chain.map(\.epochId) ?? [])
        let holding = all.filter { s in
            guard s.epoch > m.epoch, let parent = (try? readManifest(s.manifest))?.parent else { return false }
            return pinned.contains(parent) || s.shown(at: location)
        }
        guard let first = holding.min(by: { $0.seen < $1.seen }) else { return nil }
        return ("this device met a later device list (epoch \(first.epoch), at \(first.source)) it has not verified; a "
            + "two-way run with the vault's key checks it", first.seen)
    }

    /// Forgets the detached sightings (`sempere devices status --forget-sightings`), or every one with
    /// `anchoredToo` (`--all`: including one that makes this device unlisted, which then writes again until it
    /// meets the change again). Returns how many it forgot.
    @discardableResult
    public func forgetSightings(anchoredToo: Bool = false) throws -> Int {
        guard let trustStore else { return 0 }
        let all = sightings()
        let kept = anchoredToo ? [] : all.filter { isAnchoredSighting($0) }
        try trustStore.saveSightings(kept, for: vaultId)
        return all.count - kept.count
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
        // Only anchored sightings hold every run (and show at open); a detached one holds runs on its targets only.
        for s in sightings() where s.epochId != manifest.epochId && isAnchoredSighting(s) {
            switch judgeIncoming(s.manifest) {
            case .unlisted(let n): unlisted = unlisted ?? n
            case .waiting(let why): waiting = waiting ?? "\(why) (seen at \(s.source))"
            default: break
            }
        }
        return (unlisted, waiting)
    }
}
