import Age
import Foundation
import Sempere
import SempereRender

// Joining and taking over in the app (key-hierarchy design §6.2, §6.3; phase KH5). Joining by approval: this
// device makes its keys (the signing pair in the Secure Enclave), writes a join request into its copy, and shows
// six words and a QR code of its commitment; its runs carry the request to the targets and take home's approval
// (`joinIdentity`); the user then types home's six reply words, which check the vault against the root the reply
// names (`Vault.confirmJoin`). On home, Add Device approves a request found by the six words typed (or the QR code
// scanned) and shows the reply. The takeover (a lost or stolen home, or a kit join) is signed with the recovery
// key, from the kit or the passphrase copy, with the devices the user keeps (`Vault.takeoverPlan`, `takeover`).

/// Where a join of the open (locked) vault stands on this device.
enum JoinStage: Equatable, Sendable {
    /// The request is out: home types these words (or scans the code). The approval arrives with a sync.
    case waiting(words: [String], qr: String)
    /// Home approved: the user types home's reply words.
    case confirming
}

/// Home's reply after approving a device (design §6.2 step 3): six words, and a QR code of the vault, root and
/// frontier.
struct JoinReply: Equatable, Sendable {
    var deviceName: String
    var words: [String]
    var qr: String
}

/// A takeover about to be signed (design §6.3): its candidates and what it drops.
struct TakeoverDraft: Sendable {
    var recovery: MLKEM768X25519Identity
    /// The root to check the chain against: from the passphrase copy, the kit, or nil for a device that keeps a
    /// trust record of the vault.
    var root: Data?
    var plan: Vault.TakeoverPlan
    /// Keys made for a device joining by the kit (nil: this device's own).
    var newKeys: DeviceKeys?
}

extension AppModel {
    // MARK: - Joining (the new device)

    /// The QR payload of `request`'s commitment (design §6.2 step 1): base64 of `JoinCodes.commitmentQR`.
    nonisolated static func commitmentQRText(_ request: JoinRequest) -> String {
        JoinCodes.commitmentQR(vaultId: request.vaultId, commitment: request.commitment).base64EncodedString()
    }

    /// The six words and the code of this device's request for `vault` (computed from its keys).
    nonisolated static func joinCodes(_ keys: DeviceKeys, vaultId: UUID, kind: String) -> (words: [String], qr: String) {
        let request = keys.joinRequest(vaultId: vaultId, name: "", kind: kind)
        return (JoinCodes.words(request.commitment), commitmentQRText(request))
    }

    /// Starts this device's join of the open, locked vault: new keys (stored), the request written into the
    /// copy, the runs switched to taking the approval. Returns the stage to show.
    func startJoin(store: any DeviceKeyStore) async throws -> JoinStage {
        guard let locked = vault, let url = vaultURL, phase == .locked else { throw ModelError.noVaultOpen }
        let keys = try store.generate()
        let kind = ThisDevice.kind, name = ThisDevice.name
        // The keys first: a request whose keys are not kept could never be confirmed (review of #88, M3).
        try await store.save(keys, for: locked.vaultId, vaultName: vaultName ?? "")
        do {
            _ = try await offMain { try Vault.writeJoinRequest(at: url, device: keys, name: name, kind: kind) }
        } catch {
            try? await store.delete(for: locked.vaultId)
            throw error
        }
        joinIdentity = keys.nativeIdentity
        syncSessions.forEach { $0.demand() }
        let codes = Self.joinCodes(keys, vaultId: locked.vaultId, kind: kind)
        return .waiting(words: codes.words, qr: codes.qr)
    }

    /// Where this device's keys stand in the open, locked vault.
    enum JoinCheck: Equatable {
        /// Listed and confirmed: they unlock it.
        case member
        case stage(JoinStage)
        /// Not listed, and no request of them in the copy: a join that cannot go on (a failed kit join, a request
        /// home deleted). The keys are offered to be forgotten (review of #88, S3).
        case stray
    }

    /// Where this device's join of the open, locked vault stands, from its keys: a member when the vault lists the
    /// keys and this device confirmed it, `.confirming` when listed but not confirmed yet, `.waiting` while its
    /// request is in the copy (the runs then keep looking for the approval), else stray.
    func joinStage(_ keys: DeviceKeys) async -> JoinCheck {
        guard let locked = vault, let url = vaultURL else { return .member }
        let trust = self.trust
        let listed = locked.manifest.devices.contains { $0.key == keys.key }
        if listed {
            let unconfirmed = await Task.detached(priority: .userInitiated) { () -> Bool in
                guard let v = try? Vault.open(at: url, identities: [keys.nativeIdentity], signing: keys.signing, trust: trust)
                else { return false }
                return v.listStatus.problem?.reason == .rootUnconfirmed
            }.value
            return unconfirmed ? .stage(.confirming) : .member
        }
        let request = url.appendingPathComponent("joins").appendingPathComponent(
            keys.joinRequest(vaultId: locked.vaultId, name: "", kind: "").fileName)
        guard FileManager.default.fileExists(atPath: request.path) else { return .stray }
        joinIdentity = keys.nativeIdentity
        let codes = Self.joinCodes(keys, vaultId: locked.vaultId, kind: ThisDevice.kind)
        return .stage(.waiting(words: codes.words, qr: codes.qr))
    }

    /// The open vault's `vault.json` as on disk now (a run may have taken the approval since it opened).
    func refreshLockedManifest() async {
        guard phase == .locked, let url = vaultURL, let gen = Optional(generation) else { return }
        guard let fresh = try? await offMain({ try Vault.open(at: url) }), generation == gen, phase == .locked else { return }
        replaceLockedVault(fresh)
    }

    /// Confirms the join with home's six reply words (design §6.2 step 4): checks them against this device's
    /// commitment, the vault's root and frontier, saves the trust record, then unlocks.
    func confirmJoin(words: [String], keys: DeviceKeys) async throws {
        guard let url = vaultURL else { throw ModelError.noVaultOpen }
        let trust = self.trust
        try await offMain {
            var v = try Vault.open(at: url, identities: [keys.nativeIdentity], signing: keys.signing, trust: trust)
            try v.confirmJoin(words: words)
        }
        joinIdentity = nil
        try await unlock(device: keys, awaitNotes: false)
    }

    /// The six reply words a scanned reply code stands for (design §6.2 step 4): the code names the vault, its
    /// root and home's frontier, and the words are computed from them with this device's commitment, so they
    /// check exactly what typed words check. Nil for a code of another vault.
    func replyWords(fromQR text: String, keys: DeviceKeys) -> [String]? {
        guard let vault, let r = JoinCodes.parseReplyQR(text), r.vaultId == vault.vaultId else { return nil }
        let kind = vault.manifest.devices.first { $0.key == keys.key }?.kind ?? ThisDevice.kind
        let c = JoinRequest.commitment(vaultId: vault.vaultId, key: keys.key, sign: keys.sign, kind: kind)
        return JoinCodes.words(JoinCodes.reply(vaultId: vault.vaultId, commitment: c, root: r.root, frontier: r.frontier))
    }

    /// Gives a join up: the request and this device's keys for the vault go.
    func cancelJoin(store: any DeviceKeyStore) async {
        guard let locked = vault else { return }
        if let url = vaultURL, let keys = try? await store.keys(for: locked.vaultId, reason: "") {
            let file = url.appendingPathComponent("joins").appendingPathComponent(
                keys.joinRequest(vaultId: locked.vaultId, name: "", kind: "").fileName)
            try? FileManager.default.removeItem(at: file)
        }
        try? await store.delete(for: locked.vaultId)
        joinIdentity = nil
    }

    // MARK: - Approving (home)

    /// The join requests waiting in the open vault's `joins/`, readable and of this vault, at most `limit` (their
    /// names are storage's to choose: shown, never trusted), read off the main actor.
    func pendingJoinRequests(limit: Int = 20) async -> [JoinRequest] {
        guard let vault else { return [] }
        return await Task.detached(priority: .userInitiated) {
            Array(vault.joinRequests().compactMap(\.request).filter { $0.vaultId == vault.vaultId }.prefix(limit))
        }.value
    }

    /// Approves the request whose commitment `words` (typed) or `qr` (scanned) gives (design §6.2 step 2), after
    /// the device owner proves they are there; returns the reply to show. Under the vault's write lock.
    func approveDevice(words: [String]?, qr: String?) async throws -> JoinReply {
        guard let start = vault, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireWritableVault()
        let request: JoinRequest?
        if let qr, let data = Data(base64Encoded: qr), let parsed = JoinCodes.parseCommitmentQR(data) {
            request = parsed.vaultId == start.vaultId
                ? start.joinRequests().compactMap(\.request).first { $0.vaultId == start.vaultId && $0.commitment == parsed.commitment }
                : nil
        } else if let words {
            request = start.joinRequest(matching: words)
        } else {
            request = nil
        }
        guard let request else { throw DeviceJoinError.noMatchingRequest }
        try await ownerAuthenticator.authenticate(reason: String(localized: "Let a new device into the vault"))
        let gen = generation
        let lock = vaultWriteLock
        let (next, reply) = try await offMain { () throws -> (Vault, [String]) in
            var v = start
            let reply = try Self.withWriteLock(lock) { try v.approveDevice(request) }
            return (v, reply)
        }
        try ensureCurrent(gen)
        adoptReopened(next)
        syncSessions.forEach { $0.demand() }
        return JoinReply(deviceName: DeviceName.display(request.name), words: reply,
                         qr: JoinCodes.replyQR(vaultId: next.vaultId, root: next.root, frontier: next.manifest.epochId))
    }

    // MARK: - Takeover (design §5.6 rule 3, §6.3)

    /// The recovery key and root from what the user gave: the passphrase of the vault's passphrase copy (which
    /// carries the root), or the kit's key text with its root (16 groups typed, or the root QR scanned).
    func recoveryForTakeover(keyText: String?, rootText: String?, passphrase: String?) async throws
        -> (identity: MLKEM768X25519Identity, root: Data?) {
        guard let current = vault else { throw ModelError.noVaultOpen }
        if let passphrase, !passphrase.isEmpty {
            let copy = try await offMain { try current.openPassphraseCopy(passphrase: passphrase) }
            return (copy.identity, copy.root)
        }
        guard let keyText, case .mlkem768x25519(let pq)? = try? IdentityFile.parse(keyText) else {
            throw DeviceJoinError.notARecoveryKey
        }
        var root: Data?
        if let rootText, !rootText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let qr = KitRecovery.parseRootQR(rootText) {
                guard qr.vaultId == current.vaultId else { throw DeviceJoinError.otherVaultsRoot }
                root = qr.root
            } else {
                guard let typed = KitRecovery.parseRootText(rootText) else { throw DeviceJoinError.rootUnreadable }
                root = typed
            }
        }
        return (pq, root)
    }

    /// The takeover's plan: its parent, the devices to pick from (the current list checked, devices a later epoch
    /// removed unchecked) and the epochs it drops. A device with keys for the vault takes over as itself; one
    /// without (a kit join) gets new keys, stored once the takeover is written.
    func planTakeover(recovery: MLKEM768X25519Identity, root: Data?, store: any DeviceKeyStore) async throws -> TakeoverDraft {
        guard let current = vault, let url = vaultURL else { throw ModelError.noVaultOpen }
        let own: DeviceKeys?
        if phase == .unlocked, let mine = unlockKeys.device {
            own = mine
        } else if await store.hasKeys(for: current.vaultId) {
            own = try await store.keys(for: current.vaultId, reason: String(localized: "Take over with the recovery kit"))
        } else {
            own = nil
        }
        let keys = try own ?? store.generate()
        let trust = self.trust
        // A device with no record of the vault needs the root (design §4.3 step 4).
        let hasRecord = ((try? trust?.record(for: current.vaultId)) ?? nil) != nil
        if !hasRecord, root == nil { throw DeviceJoinError.rootNeeded }
        let plan = try await offMain { try Vault.takeoverPlan(at: url, device: keys, recovery: recovery, trust: trust, root: root) }
        return TakeoverDraft(recovery: recovery, root: root, plan: plan, newKeys: own == nil ? keys : nil)
    }

    /// Signs the takeover with the devices in `keep` (design §6.3): this device becomes home. The vault opens
    /// (again) under the new epoch; a kit join's new keys are stored first.
    func takeOver(_ draft: TakeoverDraft, keep: Set<Data>, store: any DeviceKeyStore) async throws -> EpochChangeReport {
        guard let current = vault, let url = vaultURL else { throw ModelError.noVaultOpen }
        let keys: DeviceKeys
        if let fresh = draft.newKeys {
            try await store.save(fresh, for: current.vaultId, vaultName: vaultName ?? "")
            keys = fresh
        } else if let mine = unlockKeys.device {
            keys = mine
        } else {
            keys = try await store.keys(for: current.vaultId, reason: String(localized: "Take over with the recovery kit"))
        }
        if phase == .unlocked { _ = await syncBeforeDeviceChange() }
        isChangingKeys = true
        defer { isChangingKeys = false }
        await editGate.acquire()
        defer { editGate.release() }
        try? await openEditor(for: nil)
        await closeWindowEditors()
        let trust = self.trust, stores = writeStores, root = draft.root, recovery = draft.recovery
        let name = ThisDevice.name, kind = ThisDevice.kind
        let next: Vault, report: EpochChangeReport
        do {
            (next, report) = try await offMain {
                try Vault.takeover(at: url, device: keys, recovery: recovery, keep: keep, name: name, kind: kind, trust: trust,
                                   root: root, ledger: stores?.ledger(for: current.vaultId), setAside: stores?.setAside)
            }
        } catch {
            // A kit join that did not happen leaves no keys behind (review of #88, S3).
            if draft.newKeys != nil { try? await store.delete(for: current.vaultId) }
            throw error
        }
        // The takeover was this device's: acknowledged, never alerted.
        takeoverDefaults.set(next.manifest.epoch, forKey: Self.takeoverAckKey(next.vaultId))
        isChangingKeys = false
        if phase == .unlocked {
            adoptReopened(next)
            syncSessions.forEach { $0.demand() }
        } else {
            try await unlock(device: keys, awaitNotes: false)
        }
        return report
    }
}

/// Why a join, an approval or a takeover could not go on.
enum DeviceJoinError: Error, Equatable, CustomStringConvertible {
    case noMatchingRequest
    case notARecoveryKey
    case rootNeeded
    case rootUnreadable
    case otherVaultsRoot

    var description: String {
        switch self {
        case .noMatchingRequest:
            return String(localized: "No device that asked to join has these words. Check them on the new device, and sync both devices.")
        case .notARecoveryKey:
            return String(localized: "That is not a recovery key (AGE-SECRET-KEY-PQ-1…).")
        case .rootNeeded:
            return String(localized: "This device has not opened the vault before: type the root fingerprint from the kit too (16 groups), or use the passphrase.")
        case .rootUnreadable:
            return String(localized: "The root fingerprint is 16 groups of 4 letters and digits (0–9, a–f).")
        case .otherVaultsRoot:
            return String(localized: "That root fingerprint belongs to another vault.")
        }
    }
}
