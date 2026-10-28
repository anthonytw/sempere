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

/// What Add Device found when it last looked (`lookForJoinRequests`): the requests in the copy after a sync of every
/// target, and whether a run left one arriving (listed by the target's provider, not delivered yet).
struct JoinRequestLookout: Sendable {
    var requests: [JoinRequest]
    var arriving: Bool
    var checked: Date
}

/// Add Device's approving (review of #117, B1): the look every `joinLookInterval`, words typed before their request
/// arrived (approved by the look once it has), and the button. One approval at a time: `approve` claims `working`
/// before its first wait, and nothing approves once the sheet is closed (`cancel`), which every wait re-checks.
@MainActor
@Observable
final class AddDeviceApproval {
    /// Words typed (or a code scanned) before their request arrived.
    struct Pending: Equatable {
        var words: [String]?
        var qr: String?
    }

    /// The sheet's model (set when the sheet shows).
    @ObservationIgnored weak var model: AppModel?
    private(set) var lookout: JoinRequestLookout?
    private(set) var reply: JoinReply?
    private(set) var working = false
    private(set) var failure: String?
    private(set) var pending: Pending?
    /// The sheet was closed: no look and no approval from now on.
    private(set) var closed = false
    /// Approvals this sheet made (at most one).
    private(set) var approvals = 0

    init(model: AppModel? = nil) { self.model = model }

    /// May an approval or a look go on now.
    var active: Bool { !closed && reply == nil }

    /// The sheet went (Cancel, Done, a swipe): what is waiting is dropped, and an approval past its waits stops.
    func close() {
        closed = true
        pending = nil
    }

    /// Other words typed: the ones waiting for their request are dropped.
    func wordsChanged() { pending = nil }

    /// Approves `words` or `qr`; false when another approval is going, the sheet is closed or a reply is in.
    @discardableResult
    func approve(words: [String]?, qr: String?) async -> Bool {
        guard let model, active, !working else { return false }
        working = true   // before any wait: a second trigger meanwhile does nothing
        failure = nil
        defer { working = false }
        do {
            let r = try await model.approveDevice(words: words, qr: qr) { [weak self] in self?.closed == false }
            reply = r
            pending = nil
            approvals += 1
            return true
        } catch is CancellationError {
        } catch let error as DeviceJoinError where error == .requestNotArrived || error == .requestArriving {
            // Not here yet: approved when it arrives (`look`), unless other words are typed.
            if active { pending = Pending(words: words, qr: qr) }
            failure = DeviceChangeText.message(error)
        } catch {
            pending = nil
            failure = DeviceChangeText.message(error)
        }
        return false
    }

    /// Declines `request` (its Decline button): gone from the list at once, from the targets with the next run. Words
    /// waiting for it are dropped.
    @discardableResult
    func decline(_ request: JoinRequest) async -> Bool {
        guard let model, active, !working else { return false }
        working = true
        failure = nil
        defer { working = false }
        do {
            try await model.declineJoinRequest(request.fileName)
            lookout?.requests.removeAll { $0.fileName == request.fileName }
            if let p = pending, let words = p.words, JoinCodes.matches(words, request.commitment) { pending = nil }
            return true
        } catch {
            failure = DeviceChangeText.message(error)
            return false
        }
    }

    /// One look: a sync of every target and the copy's requests; then the waiting words, if their request is here.
    func look() async {
        guard let model, active, !working else { return }
        let found = await model.lookForJoinRequests()
        guard active else { return }
        lookout = found
        guard let p = pending, !working else { return }
        let here = await model.hasJoinRequest(words: p.words, qr: p.qr)
        guard here, active, !working, pending == p else { return }
        await approve(words: p.words, qr: p.qr)
    }
}

/// Where this device's join request stands on its way out (the join screen; build 11, where an iPad's request seemed
/// never to reach the Mac): written into the copy, taken by a run into the sync target, then uploaded by the target's
/// provider (iCloud Drive) before another device can see it.
enum JoinDelivery: Equatable, Sendable {
    /// No run has taken the request to a target since it was made.
    case sending
    /// A run put it into the target's folder, and its provider has not uploaded it yet (`ProviderUploads`).
    case waitingForUpload(iCloud: Bool)
    /// In the target: the device that manages devices finds it with its next sync.
    case sent
    /// The last run failed; the text is the session's.
    case problem(String)

    /// What one target's session says (`SyncSession`), for `judge`.
    struct Target: Sendable {
        var lastAttempt: Date?
        var syncing: Bool
        var failure: String?
        var joinsError: Bool
        var providerPending: Int
        var viaICloud: Bool
    }

    /// The request was made at `requestedAt` (nil: unknown, any run counts). A target holds it once a run started
    /// after it ended without failing and without an error for `joins/`.
    static func judge(requestedAt: Date?, targets: [Target]) -> JoinDelivery {
        let carried = targets.filter { t in
            guard let last = t.lastAttempt, !t.syncing, t.failure == nil, !t.joinsError else { return false }
            return requestedAt.map { last >= $0 } ?? true
        }
        if carried.isEmpty {
            if let failed = targets.first(where: { $0.failure != nil && !$0.syncing })?.failure { return .problem(failed) }
            return .sending
        }
        if let waiting = carried.first(where: { $0.providerPending > 0 }) { return .waitingForUpload(iCloud: waiting.viaICloud) }
        return .sent
    }

    /// The join screen's line.
    var text: String {
        switch self {
        case .sending:
            return String(localized: "Sending the request to the vault's sync target…")
        case .waitingForUpload(let iCloud):
            return iCloud
                ? String(localized: "Waiting for iCloud Drive to upload the request. It can take a minute or two; keep this screen open.")
                : String(localized: "Waiting for the sync folder's storage to upload the request. Keep this screen open.")
        case .sent:
            return String(localized: "The request is in the sync target. On the device that manages devices, open Add Device and type these words.")
        case .problem(let why):
            return String(localized: "The request could not be sent yet: \(why)", comment: "Join screen; the value is the sync problem")
        }
    }
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
        // An earlier request of this device (it asked before and gave up without Cancel) is withdrawn now that the new
        // one is written: the new keys supersede it, and home is never left with a request nobody will confirm (build
        // 12). Not before: a failure above leaves the earlier join as it was (review of #124, note 1).
        let fresh = keys.joinRequest(vaultId: locked.vaultId, name: "", kind: "").fileName
        if let previous = joinRequestedFile(locked.vaultId), previous != fresh {
            try? FileManager.default.removeItem(at: url.appendingPathComponent("joins").appendingPathComponent(previous))
        }
        setJoinRequested(keys, vaultID: locked.vaultId)
        syncSessions.forEach { $0.demand() }
        let codes = Self.joinCodes(keys, vaultId: locked.vaultId, kind: kind)
        return .waiting(words: codes.words, qr: codes.qr)
    }

    // MARK: - The join-requested marker (re-check of #88, stray)

    /// This device asked to join `vaultID` with `keys` and has neither confirmed nor given up: while it is set, a
    /// copy without the request file (home took it with its approval, which has not arrived) still counts as
    /// waiting, never as keys to forget. Kept as the keys' fingerprint and the time of the request.
    func setJoinRequested(_ keys: DeviceKeys, vaultID: UUID, at date: Date = Date()) {
        takeoverDefaults.set("\(Self.idText(keys.fingerprint)) \(RFC3339.string(date))", forKey: Self.joinRequestedKey(vaultID))
    }

    func clearJoinRequested(_ vaultID: UUID) {
        takeoverDefaults.removeObject(forKey: Self.joinRequestedKey(vaultID))
    }

    /// The marker of `keys`' join of `vaultID`.
    enum JoinMarker: Equatable { case none, open, lapsed }

    /// The marker lapses once home has deleted the request, which it does `joinRequestLifetime` after the request
    /// (design §6.2; second re-check of #88): the join is over, and the device is told to join again.
    func joinRequested(_ keys: DeviceKeys, vaultID: UUID, now: Date = Date()) -> JoinMarker {
        guard let text = takeoverDefaults.string(forKey: Self.joinRequestedKey(vaultID)) else { return .none }
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first == Self.idText(keys.fingerprint) else { return .none }
        guard parts.count == 2, let date = RFC3339.parse(parts[1]) else { return .lapsed }
        return now.timeIntervalSince(date) > Self.joinRequestLifetime ? .lapsed : .open
    }

    /// The file name of the request this device's open join of `vaultID` wrote (from its marker: the keys'
    /// fingerprint names the file, `JoinRequest.fileName`); nil without one.
    func joinRequestedFile(_ vaultID: UUID) -> String? {
        guard let text = takeoverDefaults.string(forKey: Self.joinRequestedKey(vaultID)),
              let fingerprint = text.split(separator: " ").first, fingerprint.count >= 8 else { return nil }
        let name = "\(fingerprint.prefix(8)).join.json"
        return Vault.isJoinRequestName(name) ? name : nil
    }

    /// When this device asked to join `vaultID` (its marker), whatever keys asked.
    func joinRequestedAt(_ vaultID: UUID) -> Date? {
        guard let text = takeoverDefaults.string(forKey: Self.joinRequestedKey(vaultID)) else { return nil }
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? RFC3339.parse(parts[1]) : nil
    }

    /// Where this device's join request of the open vault stands on its way to the other devices (the join screen).
    var joinDelivery: JoinDelivery {
        let requestedAt = vault.flatMap { joinRequestedAt($0.vaultId) }
        return JoinDelivery.judge(requestedAt: requestedAt, targets: syncSessions.map { s in
            JoinDelivery.Target(lastAttempt: s.schedule.lastAttempt, syncing: s.isSyncing, failure: s.failure,
                                joinsError: s.lastReport?.errors.contains { $0.path.hasPrefix("joins") } == true,
                                providerPending: s.providerPending, viaICloud: s.uploadsViaICloud)
        })
    }

    /// How long home keeps a join request before it deletes it (design §6.2; `SyncEngine`'s rule).
    nonisolated static let joinRequestLifetime: TimeInterval = 7 * 86_400

    nonisolated static func joinRequestedKey(_ vaultID: UUID) -> String {
        "Sempere.joinRequested.\(vaultID.uuidString.lowercased())"
    }

    /// Where this device's keys stand in the open, locked vault.
    enum JoinCheck: Equatable {
        /// Listed and confirmed: they unlock it.
        case member
        case stage(JoinStage)
        /// Not listed, no request of them in the copy, and no join of them asked for here and still open: keys a
        /// join cannot go on with (a failed kit join, a request home deleted). They are offered to be forgotten
        /// (review of #88, S3).
        case stray
        /// Not listed, no request in the copy, and this device's request is older than home keeps one: home deleted
        /// it. The device joins again (second re-check of #88).
        case expired
    }

    /// Where this device's join of the open, locked vault stands, from its keys: a member when the vault lists the
    /// keys and this device confirmed it, `.confirming` when listed but not confirmed yet, `.waiting` while its
    /// request is in the copy or its join is still open here (`joinRequested`) (the runs then keep looking for the approval), else stray.
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
        // No request in the copy: home may have taken it with an approval this copy has not received yet, until
        // home would have deleted it anyway.
        if !FileManager.default.fileExists(atPath: request.path) {
            switch joinRequested(keys, vaultID: locked.vaultId) {
            case .none: return .stray
            case .lapsed: return .expired
            case .open: break
            }
        }
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
        if let id = vault?.vaultId { clearJoinRequested(id) }
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
        // By the marker too, without the keys (a Keychain read that failed): the request is withdrawn either way.
        if let url = vaultURL, let file = joinRequestedFile(locked.vaultId) {
            try? FileManager.default.removeItem(at: url.appendingPathComponent("joins").appendingPathComponent(file))
        }
        try? await store.delete(for: locked.vaultId)
        clearJoinRequested(locked.vaultId)
        joinIdentity = nil
        // The withdrawal goes out with the next run: the targets drop the request (one side deleted it since both
        // held it), so home never waits on it (build 12).
        syncSessions.forEach { $0.demand() }
    }

    // MARK: - Declining (home)

    /// Declines a waiting request (Add Device's Decline, `sempere devices decline`): deleted from the copy under the
    /// vault's write lock; the next runs delete it on the targets.
    func declineJoinRequest(_ fileName: String) async throws {
        guard let current = vault, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireWritableVault()
        let lock = vaultWriteLock
        _ = try await offMain { try Self.withWriteLock(lock) { try current.declineJoinRequests([fileName]) } }
        syncSessions.forEach { $0.demand() }
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

    /// Add Device's look for requests (build 11: a request iCloud Drive delivered after the sheet opened was never
    /// seen, and typed words matched only what the copy held then): every target of the open vault is synced now,
    /// then the copy's `joins/` is read.
    func lookForJoinRequests() async -> JoinRequestLookout {
        await syncAllTargetsNow()
        let requests = await pendingJoinRequests()
        return JoinRequestLookout(requests: requests, arriving: joinRequestArriving, checked: Date())
    }

    /// The last run of a target of the open vault left a join request (or the `joins/` folder) arriving: the
    /// target's provider (iCloud Drive) listed it but has not delivered its bytes yet.
    var joinRequestArriving: Bool {
        syncSessions.contains { s in
            s.lastReport?.arriving.contains { $0.path.hasPrefix(Self.joinsPrefix) } == true
        }
    }

    /// Where join requests are in a vault and in a target (`format.md` §15.12), as sync reports name them.
    nonisolated static let joinsPrefix = "joins/"

    /// Whether the copy holds the request six typed words (or a scanned code) name, read off the main actor: Add
    /// Device approves them again once their request has arrived.
    func hasJoinRequest(words: [String]?, qr: String?) async -> Bool {
        guard let vault else { return false }
        return await Task.detached(priority: .userInitiated) { Self.joinRequest(in: vault, words: words, qr: qr) != nil }.value
    }

    /// The request in `vault`'s copy that `words` (typed) or `qr` (scanned) names; nil when none is there.
    nonisolated static func joinRequest(in vault: Vault, words: [String]?, qr: String?) -> JoinRequest? {
        if let qr, let data = Data(base64Encoded: qr), let parsed = JoinCodes.parseCommitmentQR(data) {
            guard parsed.vaultId == vault.vaultId else { return nil }
            return vault.joinRequests().compactMap(\.request).first { $0.vaultId == vault.vaultId && $0.commitment == parsed.commitment }
        } else if let words {
            return vault.joinRequest(matching: words)
        }
        return nil
    }

    /// Approves the request whose commitment `words` (typed) or `qr` (scanned) gives (design §6.2 step 2), after
    /// the device owner proves they are there; returns the reply to show. Under the vault's write lock.
    ///
    /// A request not in the copy yet is looked for once more after syncing every target: the new device's request
    /// travels through them, and a provider such as iCloud Drive may deliver it only after the last run. Still
    /// missing, it throws `requestArriving` when a run left a request arriving, else `noMatchingRequest`.
    ///
    /// `proceed` is asked after each wait (the sync, the owner check): false (the sheet was closed) stops it with
    /// `CancellationError` before anything is written.
    func approveDevice(words: [String]?, qr: String?, proceed: () -> Bool = { true }) async throws -> JoinReply {
        guard let first = vault, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireWritableVault()
        var start = first
        var found = await Task.detached(priority: .userInitiated) { Self.joinRequest(in: first, words: words, qr: qr) }.value
        guard proceed() else { throw CancellationError() }
        let synced = found == nil && !syncSessions.isEmpty
        if synced {
            await syncAllTargetsNow()
            guard proceed() else { throw CancellationError() }
            guard let again = vault, phase == .unlocked, again.vaultId == first.vaultId else { throw KeyError.notUnlocked }
            // The run may have taken a vault.json that makes this device read-only or not home (review of #117, N1).
            try requireWritableVault()
            start = again
            found = await Task.detached(priority: .userInitiated) { Self.joinRequest(in: again, words: words, qr: qr) }.value
            guard proceed() else { throw CancellationError() }
        }
        guard let request = found else {
            if joinRequestArriving { throw DeviceJoinError.requestArriving }
            // With no target nothing can arrive: no word of syncs or iCloud Drive then.
            throw synced ? DeviceJoinError.requestNotArrived : DeviceJoinError.noMatchingRequest
        }
        try await ownerAuthenticator.authenticate(reason: String(localized: "Let a new device into the vault"))
        guard proceed() else { throw CancellationError() }
        guard vault?.vaultId == start.vaultId, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireWritableVault()
        let gen = generation
        let lock = vaultWriteLock
        let approving = start
        let (next, reply) = try await offMain { () throws -> (Vault, [String]) in
            var v = approving
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
        // The takeover was this device's: acknowledged (by id, as `applyTakeovers` keeps them), never alerted.
        let ackKey = Self.takeoverAckKey(next.vaultId)
        let acknowledged = (takeoverDefaults.stringArray(forKey: ackKey) ?? []) + [Self.idText(next.manifest.epochId)]
        takeoverDefaults.set(Array(acknowledged.suffix(Self.acknowledgedTakeoversLimit)), forKey: ackKey)
        clearJoinRequested(next.vaultId)
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
    /// No request with the words, and no target a request could come through.
    case noMatchingRequest
    /// No request with the words in the copy even after syncing every target: it may not have arrived yet.
    case requestNotArrived
    /// No request with the words is in the copy yet, and a run left a request arriving: the provider has listed it
    /// but not delivered it.
    case requestArriving
    case notARecoveryKey
    case rootNeeded
    case rootUnreadable
    case otherVaultsRoot

    var description: String {
        switch self {
        case .noMatchingRequest:
            return String(localized: "No device that asked to join has these words. Check them on the new device.")
        case .requestNotArrived:
            return String(localized: "No request with these words has arrived yet. Check the words on the new device. Its request comes through the vault's sync target, and iCloud Drive can take a minute or two to deliver it: keep this open, and Sempere approves it when it arrives.")
        case .requestArriving:
            return String(localized: "A request is on its way: the sync target's storage (such as iCloud Drive) has listed it but not delivered it yet. Keep this open, and Sempere approves it when it arrives.")
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
