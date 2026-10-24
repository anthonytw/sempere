import Crypto
import Foundation

// Checking `vault.json` against what this device verified (docs/design/key-hierarchy.md §4.3; format.md
// §15.3, §15.10), for single-epoch vaults (KH2). The checks that need no chain are
// `EpochManifest.check`'s; this file adds the root, the trust record, and the record itself.

extension Vault {
    /// Classifies `manifest` for a device holding `key` (from its own wrap).
    ///
    /// - The root must be the one epoch 1's key gives (this device holds `K_1`), the trust record's, and
    ///   `root` when given.
    /// - With a trust record: the same epoch and `epochId` as the pinned one, every check of
    ///   `EpochManifest.check` against the list it verified, no entry it verified gone or changed but
    ///   for its name, and markers at least those it verified.
    /// - Without one: the checks against epoch 1's first list. A device with a trust store that has no
    ///   record and was given no root cannot confirm the vault (`rootUnconfirmed`): it reads, and writes
    ///   once the join's reply code (or the kit's root) confirmed it.
    static func listStatus(_ manifest: EpochManifest, key: VaultEpochKey, trust: (any EpochTrustStore)?,
                           root expected: Data?) -> ListStatus {
        listCheck(manifest, key: key, trust: trust, root: expected, record: .notRead).status
    }

    /// The current epoch's record as `open` found it.
    enum RecordRead {
        /// Epoch 1: its record is not needed to check `vault.json`.
        case notRead
        case read(EpochRecord)
        /// Missing, or its bytes are not the ones `vault.json` names, or it does not open.
        case problem(ListProblem)
    }

    /// What `listCheck` found: the status, and above epoch 1 the verified chain (nil when refused before it
    /// verified) and the pinned epochs a takeover dropped.
    struct ListCheck {
        var status: ListStatus
        var chain: EpochChain.Verified?
        var dropped: [Data] = []
        /// When a takeover waits for its kit to be pinned (`ChainError.kitNotPinned`): the chain up to the
        /// takeover's parent, verified and followed. A writer pins it, and the next open takes the takeover
        /// (design §5.6 rule 3: "a run later").
        var pinnable: EpochChain.Verified?
    }

    /// Reads and opens the current epoch's record (design §5.2.1): bounded, its SHA-256 the one
    /// `vault.json` names, opened under `key`.
    /// True when `epochs/` here holds a file under the record name `manifest` gives whose bytes are not the ones it
    /// names (junk planted under the name): sync sets it aside and fetches the record again (review of #86, M1).
    public static func holdsWrongRecord(_ url: URL, manifest: EpochManifest) -> Bool {
        guard manifest.epoch > 1,
              let data = try? BoundedRead.contents(of: url.appendingPathComponent(manifest.epochRecord), maxBytes: EpochRecord.maxBytes)
        else { return false }
        return Data(SHA256.hash(data: data)) != manifest.epochRecordHash
    }

    static func readCurrentRecord(_ url: URL, manifest: EpochManifest, key: VaultEpochKey) -> RecordRead {
        guard manifest.epoch > 1 else { return .notRead }
        let data: Data
        do {
            data = readsWithoutLinks(url)
                ? try BoundedRead.contents(under: url, manifest.epochRecord, maxBytes: EpochRecord.maxBytes)
                : try BoundedRead.contents(of: url.appendingPathComponent(manifest.epochRecord), maxBytes: EpochRecord.maxBytes)
        } catch {
            return .problem(ListProblem(.otherEpoch, "waiting for the device-change record \(manifest.epochRecord) "
                + "(epoch \(manifest.epoch)): it has not arrived"))
        }
        guard Data(SHA256.hash(data: data)) == manifest.epochRecordHash else {
            // Junk under the record's name (anyone with storage write access can plant it): the record has not
            // arrived. Never a reason to refuse `vault.json` (review of #86, M1); sync fetches the right one.
            if Self.epochMutations.contains(.recordByNameOnly) {
                return .problem(ListProblem(.epochSig, "\(manifest.epochRecord) is not the record vault.json names"))
            }
            return .problem(ListProblem(.otherEpoch, "the file at \(manifest.epochRecord) is not the record vault.json "
                + "names: waiting for the right one (epoch \(manifest.epoch))"))
        }
        do { return .read(try EpochRecord.open(data, key: key, vaultId: manifest.vaultId, epoch: manifest.epoch)) } catch {
            return .problem(ListProblem(.epochSig, "\(manifest.epochRecord) does not open under the epoch's key: \(error)"))
        }
    }

    /// The precedence rule's view of a pinned epoch (its signatures were verified when it was pinned).
    static func node(_ c: EpochTrustRecord.ChainEpoch, parentHome: Data?) -> EpochNode? {
        guard let reason = EpochReason(rawValue: c.reason) else { return nil }
        let signer = (reason == .takeover || reason == .create) ? c.home : (parentHome ?? c.home)
        return EpochNode(epochId: c.epochId, parent: c.parent, signer: signer, reason: reason, home: c.home,
                         list: Set(c.list), recovery: c.recovery, recoverySigner: reason == .takeover ? c.recovery : nil)
    }

    /// The precedence rule's view of a verified chain.
    static func nodes(_ v: EpochChain.Verified) -> [EpochNode] {
        v.entries.enumerated().compactMap { i, e in
            guard let reason = EpochReason(rawValue: e.reason) else { return nil }
            return EpochNode(epochId: e.epochId, parent: e.parent, signer: e.author.fingerprint, reason: reason, home: e.home,
                             list: v.lists[i].list, recovery: e.recovery,
                             recoverySigner: e.recoveryAuthor?.recoveryFingerprint)
        }
    }

    /// Test-only: mutations of the precedence rule as this vault applies it (`EpochMutationTests`).
    nonisolated(unsafe) static var precedenceMutations: Set<PrecedenceMutation> = []

    /// Whether this device follows the verified chain `chain` given its pinned chain (design §5.6): the
    /// precedence rule over the union of both must keep exactly `chain`. Returns the pinned epochs it
    /// drops, or nil when it does not follow `chain`.
    static func follows(_ chain: EpochChain.Verified, pinned: [EpochTrustRecord.ChainEpoch]) -> [Data]? {
        var nodes = Self.nodes(chain)
        let ids = Set(chain.entries.map(\.epochId))
        var homeOf: [Data: Data] = [:]
        for c in pinned { homeOf[c.epochId] = c.home }
        for c in pinned where !ids.contains(c.epochId) {
            guard let n = node(c, parentHome: c.parent.flatMap { homeOf[$0] }) else { return nil }
            nodes.append(n)
        }
        guard let result = try? EpochPrecedence.resolve(nodes, pinned: pinned.map(\.epochId), mutations: precedenceMutations),
              result.keptChain == chain.entries.map(\.epochId) else { return nil }
        return result.dropped
    }

    /// Classifies `manifest` for a device holding `key` (from its own wrap), above epoch 1 with the record
    /// `record` (design §4.3):
    ///
    /// - epoch 1: the root is the one `K_1` gives; above: the record's chain verifies from the root
    ///   (`EpochChain.verify`, with the trust record's pinned chain for takeovers), its last entry is this
    ///   `vault.json`'s epoch, and the precedence rule over the pinned chain and it keeps it;
    /// - the root is the trust record's and `root` when given;
    /// - at the pinned epoch, as before (home and first list the record's, entries only added or renamed);
    /// - every check of `EpochManifest.check`, against the list this device verified (or the epoch's first
    ///   list from the chain) and the parent as the chain gives it.
    static func listCheck(_ manifest: EpochManifest, key: VaultEpochKey, trust: (any EpochTrustStore)?,
                          root expected: Data?, record recordRead: RecordRead) -> ListCheck {
        func refused(_ r: ListProblem.Reason, _ why: String) -> ListCheck { ListCheck(status: .refused(ListProblem(r, why))) }
        if manifest.epoch == 1 {
            guard let derived = try? VaultRoot.fingerprint(vaultId: manifest.vaultId, epochOne: key), derived == manifest.root else {
                return refused(.rootMismatch, "root is not the one epoch 1's key gives")
            }
        }
        if let expected, expected != manifest.root {
            return refused(.rootMismatch, "root is not the one given (the kit's, or the reply code's)")
        }
        let record: EpochTrustRecord?
        do { record = try trust?.record(for: manifest.vaultId) } catch {
            return refused(.recordUnreadable, "this device's trust record cannot be read: \(error)")
        }
        if let record, record.root != manifest.root { return refused(.rootMismatch, "root is not the one this device pinned") }
        var chain: EpochChain.Verified?
        var dropped: [Data] = []
        var parent: EpochManifest.VerifiedParent?
        if manifest.epoch > 1 {
            let epochRecord: EpochRecord
            switch recordRead {
            case .read(let r): epochRecord = r
            case .problem(let p):
                // Not arrived: a direct child of the pinned epoch, linked and signed from it, is taken; files
                // under the older key stay pending until the record arrives (design §4.3 step 2, KH4).
                if p.reason == .otherEpoch, let record, expected.map({ $0 == record.root }) ?? true,
                   recordPendingCheck(manifest, key: key, trusted: record) != nil {
                    return ListCheck(status: .verified(.newEpochRecordPending))
                }
                return ListCheck(status: .refused(p))
            case .notRead: return refused(.otherEpoch, "the record of epoch \(manifest.epoch) was not read")
            }
            let pinned = record?.chain.map { TakeoverRule.PinnedEpoch(epochId: $0.epochId, recovery: $0.recovery) } ?? []
            var directory = DeviceDirectory()
            for d in manifest.devices { if let s = d.sign { directory.add(key: d.key, sign: s) } }
            let verified: EpochChain.Verified
            do {
                verified = try EpochChain.verify(epochRecord.chain, vaultId: manifest.vaultId, root: manifest.root,
                                                 directory: directory, pinned: pinned, mutations: precedenceMutations)
            } catch ChainError.kitNotPinned(let at) {
                var check = refused(.otherEpoch, "the takeover of epoch \(at) is signed by a recovery kit this device "
                    + "has not pinned yet: it is taken once the kit's replacement is pinned (write once, then open again)")
                let prefix = Array(epochRecord.chain.prefix(at - 1))
                if let v = try? EpochChain.verify(prefix, vaultId: manifest.vaultId, root: manifest.root,
                                                  directory: directory, pinned: pinned),
                   record.map({ follows(v, pinned: $0.chain) != nil }) ?? true {
                    check.pinnable = v
                }
                return check
            } catch let e as ChainError {
                return ListCheck(status: .refused(chainProblem(e)))
            } catch {
                return refused(.epochSig, "\(error)")
            }
            guard let last = verified.entries.last, last.epochId == manifest.epochId, last.epoch == manifest.epoch,
                  last.parent == manifest.parent, last.home == manifest.home, last.reason == manifest.epochReason,
                  last.epochSig == manifest.epochSig, last.recoverySig == manifest.recoverySig,
                  last.link == manifest.epochLink, last.recovery == manifest.recoveryFingerprint,
                  Set(last.list) == Set(manifest.firstList), Set(last.parentList) == Set(manifest.parentList) else {
                return refused(.epochSig, "vault.json's epoch is not the one its record's chain ends with")
            }
            if let record, record.pinned?.epochId != manifest.epochId {
                guard let d = follows(verified, pinned: record.chain) else {
                    return ListCheck(status: .refused(ListProblem(.otherEpoch, "this device follows another chain: "
                        + "vault.json's epoch \(manifest.epoch) is older than the one it pinned, on a branch it does not "
                        + "follow, or a home conflict (design §5.6)")), chain: verified)
                }
                dropped = d
            }
            let i = manifest.epoch - 2
            parent = EpochManifest.VerifiedParent(
                list: verified.lists[i].list, home: verified.entries[i].home, recovery: verified.entries[i].recovery,
                ancestry: verified.lists[...i].reduce(into: Set<Data>()) { $0.formUnion($1.list) })
            chain = verified
        }
        var verified: Set<Data>
        let samePinned = record?.pinned?.epochId == manifest.epochId
        if let record, samePinned {
            // The pinned epoch's home and first list come from the record, never from the file (design
            // §4.3): within one epoch only home's additions and renames change the list. With them fixed,
            // `epochSig` and every `addSig` verify under the home this device verified.
            guard record.home == manifest.home else {
                return ListCheck(status: .refused(ListProblem(.entriesChanged, "the home device is not the one this device "
                    + "verified: only a handoff (a new epoch) changes it")), chain: chain)
            }
            guard let pinned = record.pinned, Set(pinned.list) == Set(manifest.firstList) else {
                return ListCheck(status: .refused(ListProblem(.entriesChanged, "the epoch's first list is not the one this "
                    + "device verified")), chain: chain)
            }
            verified = Set(record.list.map(\.fingerprint))
        } else {
            verified = Set(manifest.firstList)
        }
        let admitted: [EpochKeyEntry]
        do { admitted = try manifest.check(key: key, verifiedList: verified, parent: parent, mutations: precedenceMutations) } catch let e as EpochManifest.ProblemError {
            return ListCheck(status: .refused(problem(e.problem)), chain: chain)
        } catch {
            return ListCheck(status: .refused(ListProblem(.listTag, "\(error)")), chain: chain)
        }
        verified.formUnion(admitted.map(\.fingerprint))
        guard let record else {
            if trust != nil, expected == nil {
                return ListCheck(status: .refused(ListProblem(.rootUnconfirmed, "this device has not confirmed the vault: "
                    + "type the home device's reply words (sempere device confirm), or give the kit's root")), chain: chain)
            }
            return ListCheck(status: .verified(.firstUse), chain: chain)
        }
        guard record.markers.isCovered(by: manifest) else {
            return ListCheck(status: .refused(ListProblem(.markersRolledBack, "format or features are older than this "
                + "device verified")), chain: chain)
        }
        // A journal bound again to a re-encryption this device saw finished: an older vault.json put back (KH6).
        // `reencryptFinished` is the epoch whose vault.json this device saw without the binding: a binding at or below it
        // is a replay. (A later epoch whose home had not seen the finish carries the binding on, signed; its home then
        // finishes the re-encryption again.)
        if let finished = record.reencryptFinished, manifest.reencryptPending != nil,
           let f = chain?.entries.first(where: { $0.epochId == finished }), manifest.epoch <= f.epoch,
           let m = chain?.entries.last(where: { $0.reason == EpochReason.reencrypt.rawValue }), m.epoch <= f.epoch {
            return ListCheck(status: .refused(ListProblem(.reencryptRolledBack, "vault.json binds a re-encryption journal "
                + "this device saw finished: an older version put back")), chain: chain)
        }
        guard samePinned else { return ListCheck(status: .verified(.newEpoch), chain: chain, dropped: dropped) }
        // Under one epoch the list only grows (design §5.1): an entry this device verified is still
        // there, with the same key and signing keys (its name may change).
        let now = Dictionary(manifest.keys.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        var renamed = false
        for entry in record.list {
            guard let current = now[entry.fingerprint] else {
                return ListCheck(status: .refused(ListProblem(.entriesChanged, "\(entry.role) "
                    + "\(ListProblem.abbreviate(entry.key)) is gone under the same epoch: a removal always starts a new "
                    + "epoch")), chain: chain)
            }
            if current.name != entry.name { renamed = true }
        }
        if !admitted.isEmpty { return ListCheck(status: .verified(.added), chain: chain) }
        return ListCheck(status: .verified(renamed ? .renamed : .unchanged), chain: chain)
    }

    /// A chain that does not verify, as a list problem (the reasons the app already explains).
    static func chainProblem(_ e: ChainError) -> ListProblem {
        switch e {
        case .notRooted: return ListProblem(.rootMismatch, "the chain of device changes is not rooted at this vault's root")
        case .introducesDevice(let n):
            return ListProblem(.introducesDevice, "the device change of epoch \(n) introduces a device")
        case .kitNotPinned(let n):
            return ListProblem(.otherEpoch, "the takeover of epoch \(n) waits for its recovery kit to be pinned")
        default: return ListProblem(.epochSig, "the chain of device changes does not verify (\(e))")
        }
    }

    static func problem(_ p: EpochManifest.Problem) -> ListProblem {
        switch p {
        case .wrap: return ListProblem(.listTag, "this device's wrap is not of this epoch")
        case .listTag: return ListProblem(.listTag, "listTag does not verify: an entry was changed without the key")
        case .markersTag: return ListProblem(.markersTag, "markersTag does not verify: format or features changed")
        case .authorSig: return ListProblem(.authorSig, "authorSig is not the home device's")
        case .epochSig: return ListProblem(.epochSig, "epochSig does not verify under the epoch's author")
        case .introducesDevice: return ListProblem(.introducesDevice, "the epoch's first list introduces a device")
        case .addSig(let key):
            return ListProblem(.addSig, "\(ListProblem.abbreviate(key)) was not approved by the home device")
        }
    }

    /// Saves this device's trust record for the current (verified) list (format.md §15.10). Writers
    /// keep one, so a record that cannot be saved is an error, tried again by the next write.
    func rememberList() throws {
        guard trustStore != nil, let secret else { return }
        guard case .verified(let how) = listStatus else { return }
        // A direct child whose record has not arrived is followed but not pinned: its link keys are in the
        // record (design §4.3 step 2). The record's arrival pins it.
        if how == .newEpochRecordPending { return }
        let chain: [EpochTrustRecord.ChainEpoch]
        if let verifiedChain {
            chain = verifiedChain.entries.map(EpochTrustRecord.ChainEpoch.init)
        } else {
            guard manifest.epoch == 1, let recovery = manifest.recoveryFingerprint else {
                throw VaultError.untrustedList(ListProblem(.otherEpoch, "the chain of epoch \(manifest.epoch) did not verify"))
            }
            chain = [try .init(epoch: 1, key: secret, parent: nil, list: manifest.firstList.sorted { $0.lexicographicallyPrecedes($1) },
                               recovery: recovery, home: manifest.home, reason: manifest.epochReason)]
        }
        // A re-encryption on the chain without a journal bound is finished (design §7.1 step 7, KH6): the epoch whose
        // vault.json shows it so is remembered.
        let finished = manifest.reencryptPending == nil && chain.contains(where: { $0.reason == EpochReason.reencrypt.rawValue })
            ? manifest.epochId : nil
        try saveTrust(chain: chain, list: manifest.keys, home: manifest.home, reencryptFinished: finished)
        // The key of every epoch this device pinned (not only those it wrote under): a takeover may drop the
        // epoch later, and its files here then read as set aside (dropped) rather than unreadable, so an
        // accepted copy replaces them (design §5.4 step 4; KH4).
        if let ledger, ledgerMemo.needsKey(secret.epochId) {
            try? ledger.rememberKey(epoch: manifest.epoch, key: secret)
            ledgerMemo.keyRemembered(secret.epochId)
        }
    }

    /// Pins `pinnable` (design §5.6 rule 3): the verified chain up to the parent of a takeover signed by a
    /// kit this device has not pinned yet. The next open then takes the takeover.
    func pinDeferredPrefix() throws {
        guard let pinnable, trustStore != nil, let last = pinnable.entries.last else { return }
        let listed = Set(pinnable.lists.last?.list ?? [])
        try saveTrust(chain: pinnable.entries.map(EpochTrustRecord.ChainEpoch.init),
                      list: manifest.keys.filter { listed.contains($0.fingerprint) }, home: last.home)
    }

    private func saveTrust(chain: [EpochTrustRecord.ChainEpoch], list: [EpochKeyEntry], home: Data,
                           reencryptFinished: Data? = nil) throws {
        guard let trustStore else { return }
        var record = try EpochTrustRecord(
            vaultId: vaultId, root: manifest.root, chain: chain,
            list: list.map { EpochTrustRecord.Entry(role: $0.role.rawValue, key: $0.key, sign: $0.sign, name: $0.name) },
            markers: VaultMarkers(manifest), home: home)
        if let memo = trustMemo.last, memo.vaultId == vaultId {
            record.markers = record.markers.merged(with: memo.markers)
            record.reencryptFinished = reencryptFinished ?? memo.reencryptFinished
        } else {
            record.reencryptFinished = reencryptFinished
        }
        guard trustMemo.last != record else { return }
        if let stored = try trustStore.record(for: vaultId) {
            record.markers = record.markers.merged(with: stored.markers)
            // Kept while the chain still holds it (a takeover that drops it drops the mark too).
            if reencryptFinished == nil, let f = stored.reencryptFinished, chain.contains(where: { $0.epochId == f }) {
                record.reencryptFinished = f
            }
        }
        try trustStore.save(record)
        trustMemo.last = record
    }

    /// Confirms this device's join (design §6.2 step 4): `words` are the reply home showed. They must be
    /// the six words of `JoinCodes.reply` over this device's commitment, the root and epoch of the
    /// `vault.json` at hand: a vault storage built around this device's (public) key has another root.
    /// Then the vault is checked against that root and the trust record saved.
    ///
    /// - Throws: `locked`, `recoveryKeyReadOnly`, `replyMismatch`, `untrustedList` for a list that
    ///   still does not check.
    public mutating func confirmJoin(words: [String]) throws {
        guard let secret else { throw VaultError.locked }
        guard let entry = deviceEntry, let claim = entry.claim else { throw VaultError.recoveryKeyReadOnly }
        let commitment = JoinRequest.commitment(vaultId: vaultId, key: claim.key, sign: claim.sign, kind: claim.kind)
        let reply = JoinCodes.reply(vaultId: vaultId, commitment: commitment, root: manifest.root, frontier: manifest.epochId)
        guard JoinCodes.matches(words, reply) else { throw VaultError.replyMismatch }
        recheck(root: manifest.root, key: secret)
        try requireTrustedList()
        try rememberList()
    }

    /// Checks `vault.json` again (`listCheck`), against `root` (nil: the root given at open).
    mutating func recheck(root: Data? = nil, key: VaultEpochKey) {
        let check = Self.listCheck(manifest, key: key, trust: trustStore, root: root ?? givenRoot,
                                   record: Self.readCurrentRecord(url, manifest: manifest, key: key))
        listStatus = check.status
        verifiedChain = check.chain
        droppedEpochs = check.dropped
        pinnable = check.pinnable
    }

    /// `data` parsed, when it is a later version of this vault's `vault.json` by its home (design §5.1,
    /// one writer): the same vault, root, epoch and `epochId`, every check passes against the list this
    /// value holds, and that list's entries are all still there. Nil otherwise (also when locked): two
    /// versions whose lists do not contain each other are never merged.
    public func laterVersion(_ data: Data) -> EpochManifest? {
        guard let m = try? Self.readManifest(data), isLaterVersion(m, of: manifest) else { return nil }
        return m
    }

    /// True when `newer` is a later version than `older` of one epoch of this vault, by its home: the same
    /// vault, root, epoch and `epochId`, `newer` passes every check against `older`'s list (which it
    /// holds entirely) under this vault's key, its markers are at least `older`'s, and it adds a device or
    /// renames one. False when locked.
    public func isLaterVersion(_ newer: EpochManifest, of older: EpochManifest) -> Bool {
        guard let secret, newer.vaultId == older.vaultId, newer.vaultId == vaultId, newer.root == older.root,
              newer.epoch == older.epoch, newer.epochId == older.epochId, newer.epochId == secret.epochId,
              Self.readOnlyReasons(newer).isEmpty else { return false }
        // The epoch's head is fixed (design §4.3, §5.1): the same home, first list, parent, reason, author and
        // signature. Only the home of `older` may add devices or rename them in a later version.
        guard newer.home == older.home, Set(newer.firstList) == Set(older.firstList), newer.parent == older.parent,
              newer.epochReason == older.epochReason, newer.epochAuthor == older.epochAuthor,
              newer.epochSig == older.epochSig, newer.recoverySig == older.recoverySig,
              newer.homeEntry?.fingerprint == older.homeEntry?.fingerprint else { return false }
        let base = Set(older.keys.map(\.fingerprint))
        // Above epoch 1 the epoch's signer is its parent's home (a handoff's is not the new home): the parent as the
        // verified chain gives it, as the check at open does.
        var parent: EpochManifest.VerifiedParent?
        if newer.epoch > 1, let chain = verifiedChain, chain.entries.count >= newer.epoch, newer.epoch >= 2 {
            let i = newer.epoch - 2
            parent = EpochManifest.VerifiedParent(
                list: chain.lists[i].list, home: chain.entries[i].home, recovery: chain.entries[i].recovery,
                ancestry: chain.lists[...i].reduce(into: Set<Data>()) { $0.formUnion($1.list) })
        }
        guard base.isSubset(of: Set(newer.keys.map(\.fingerprint))),
              (try? newer.check(key: secret, verifiedList: base, parent: parent)) != nil,
              VaultMarkers(older).isCovered(by: newer) else { return false }
        // A re-encryption's binding only goes (its finish, design §7.1 step 7): never added or changed in one epoch.
        if let p = newer.reencryptPending, p != older.reencryptPending { return false }
        let finished = older.reencryptPending != nil && newer.reencryptPending == nil
        // Only the list may grow and names change; nothing else of the epoch moves.
        let names = Dictionary(newer.keys.map { ($0.fingerprint, $0.name) }, uniquingKeysWith: { a, _ in a })
        return finished || newer.keys.count > older.keys.count || older.keys.contains { names[$0.fingerprint] != $0.name }
    }

    /// Whether a `vault.json` received from elsewhere (a sync server, a provider's other version) may
    /// replace the local one (design §4.3, §5.1): nil when it may, else why not.
    ///
    /// It may when it is the local one (or differs only in the unauthenticated `label`), or, with the
    /// vault unlocked, a later version of it by home (`isLaterVersion`). Without the key nothing else can
    /// be checked, and it waits; an older version, another epoch, or one whose list does not hold the
    /// local one is never taken (no merge).
    ///
    /// - Parameters:
    ///   - data: the incoming bytes.
    ///   - local: the local `vault.json` bytes; nil on a first pull (accepted).
    ///   - vault: the local vault, opened with identities if possible.
    public static func incomingManifestProblem(_ data: Data, local: Data?, vault: Vault?) -> String? {
        let incoming: EpochManifest
        do { incoming = try readManifest(data) } catch { return "the incoming vault.json does not parse: \(error)" }
        guard let local else { return nil }
        guard let mine = try? readManifest(local) else { return nil }   // a damaged local copy: take the remote one
        guard incoming.vaultId == mine.vaultId else { return "the incoming vault.json belongs to another vault" }
        if EpochManifest.sameExceptLabel(data, local) { return nil }
        guard incoming.root == mine.root else { return "the incoming vault.json has another root: not this vault" }
        guard incoming.epoch == mine.epoch, incoming.epochId == mine.epochId else {
            return "the incoming vault.json is of another epoch (epoch \(incoming.epoch)): a device change is taken only "
                + "with its epoch record, through a shared folder (key hierarchy KH4 syncs them)"
        }
        guard let vault, vault.canRead, vault.vaultId == mine.vaultId else {
            return "the incoming vault.json changes the device list; unlock (--identity) so it can be checked (design §4.3)"
        }
        if vault.isLaterVersion(incoming, of: mine) { return nil }
        if vault.isLaterVersion(mine, of: incoming) {
            return "the incoming vault.json is an older version of the local one (fewer devices or older names)"
        }
        return "the incoming vault.json is not a later version of the local one by the home device (design §5.1): "
            + "both are kept, nothing is merged"
    }

    /// The six words this device expects as home's reply, for tests and scripted joins (the CLI never
    /// shows them: the point is that the user types the ones home shows).
    func expectedReplyWords() -> [String]? {
        guard let entry = deviceEntry, let claim = entry.claim else { return nil }
        let commitment = JoinRequest.commitment(vaultId: vaultId, key: claim.key, sign: claim.sign, kind: claim.kind)
        return JoinCodes.words(JoinCodes.reply(vaultId: vaultId, commitment: commitment, root: manifest.root,
                                               frontier: manifest.epochId))
    }
}

extension EpochTrustRecord.Entry {
    /// The entry's fingerprint (format.md §15.4).
    var fingerprint: Data {
        let p = sign?.p256Hex ?? "", m = sign?.mldsa65Hex ?? ""
        return role == EpochKeyEntry.Role.device.rawValue ? KeyFingerprint.device(key: key, signP256: p, signMLDSA65: m)
            : KeyFingerprint.recovery(key: key, signP256: p, signMLDSA65: m)
    }
}
