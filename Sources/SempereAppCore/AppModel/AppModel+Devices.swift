import Age
import Foundation
import Sempere
import SempereSync

// The device list (key-hierarchy design §5.5, §5.6, §6.4, §6.5; phase KH5): its rows and history,
// home's changes (rename, remove, Make Home, Replace Recovery Kit), and the run-up every device change shares
// (a bounded two-way run of every target first, design §5.2 step 2; the editors closed; the vault opened again
// under the new epoch, `keyEpoch`). The logic is the package's (`Vault.removeDevices`, `handOff`,
// `replaceRecoveryKit`, `deviceHistory`, `removalReview`), shared with `sempere devices`.

/// One device of the list (design §6.4). Its symbol is the app's (`DeviceRow.symbol`).
public struct DeviceRow: Identifiable, Equatable, Sendable {
    /// Who approved it.
    public enum AddedBy: Equatable, Sendable {
        /// The vault's first device: it created the vault.
        case creation
        /// A takeover's new home, approved by the recovery kit.
        case recoveryKit
        /// A listed device, by name.
        case device(String)
        /// A device no longer on the list (its id).
        case formerDevice(String)
    }

    /// The device's id (8 hex digits).
    public var id: String
    var fingerprint: Data
    public var name: String
    /// `ipad`, `iphone`, `mac`, `cli`…
    public var kind: String
    public var added: Date?
    public var addedBy: AddedBy
    /// It manages devices (design §5.6).
    public var isHome: Bool
    public var isThisDevice: Bool
    /// When it last completed a two-way sync (its own summaries file), nil when unknown.
    public var lastSynced: Date?

    public init(id: String, fingerprint: Data, name: String, kind: String, added: Date?, addedBy: AddedBy, isHome: Bool,
                isThisDevice: Bool, lastSynced: Date?) {
        self.id = id
        self.fingerprint = fingerprint
        self.name = name
        self.kind = kind
        self.added = added
        self.addedBy = addedBy
        self.isHome = isHome
        self.isThisDevice = isThisDevice
        self.lastSynced = lastSynced
    }
}

/// What the device list shows, read off the main actor (`AppModel.loadDeviceList`).
public struct DeviceListSnapshot: Equatable, Sendable {
    public var devices: [DeviceRow] = []
    /// When the current recovery kit was made.
    public var recoveryAdded: Date?
    /// A passphrase copy of the recovery key is in the vault (`keys/`).
    public var passphraseCopy = false
    /// Every device change of the chain, newest first.
    public var history: [DeviceHistoryEvent] = []
    /// Join requests waiting for home (`joins/`).
    public var joinRequests = 0
    /// This device manages devices.
    public var thisIsHome = false
    /// The device that does, by name.
    public var homeName: String?
    /// Epochs this device had followed that a takeover dropped.
    public var dropped = 0

    init(devices: [DeviceRow] = [], recoveryAdded: Date? = nil, passphraseCopy: Bool = false,
                history: [DeviceHistoryEvent] = [], joinRequests: Int = 0, thisIsHome: Bool = false, homeName: String? = nil,
                dropped: Int = 0) {
        self.devices = devices
        self.recoveryAdded = recoveryAdded
        self.passphraseCopy = passphraseCopy
        self.history = history
        self.joinRequests = joinRequests
        self.thisIsHome = thisIsHome
        self.homeName = homeName
        self.dropped = dropped
    }
}

/// What a device change did, for the sheet that started it.
public struct DeviceChangeOutcome: Equatable, Sendable {
    var report: EpochChangeReport
    /// Targets the run before the change could not reach (their names), with when each last synced.
    public var unreachable: [UnreachableTarget] = []

    public init(report: EpochChangeReport, unreachable: [UnreachableTarget] = []) {
        self.report = report
        self.unreachable = unreachable
    }
}

/// A target the best-effort run before a device change did not reach (design §5.2 step 2).
public struct UnreachableTarget: Equatable, Sendable, Identifiable {
    public var name: String
    public var lastSuccess: Date?
    public var id: String { name }

    public init(name: String, lastSuccess: Date?) {
        self.name = name
        self.lastSuccess = lastSuccess
    }
}

/// Why a device change or a read of the device list could not go on; worded by the app (`AppModel.KeyError`).
public enum AppModelKeyError: Error, Equatable, Sendable {
    case notUnlocked
    /// Another vault was opened while a sheet or dialog was up.
    case vaultChanged
}

/// A key the user gave that cannot be used; worded by the app.
public enum KeyProblem: Error, Equatable, Sendable {
    /// What was given is not the vault's recovery key from the printed kit (`AGE-SECRET-KEY-PQ-1…`).
    case recoveryKeyNeeded
}

extension AppModelCore {
    public typealias KeyError = AppModelKeyError

    // MARK: - The list

    /// The device list of the open vault: rows (with each device's last sync, read from its own summaries
    /// file), the recovery kit, the history and the requests waiting. Needs the vault unlocked.
    public func loadDeviceList() async throws -> DeviceListSnapshot {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        let gen = generation
        rememberDeviceNames(vault)
        let names = rememberedDeviceNames(vault.vaultId)
        var snapshot = try await offMain { Self.deviceListSnapshot(vault) }
        try ensureCurrent(gen)
        snapshot.history = Self.named(snapshot.history, names)
        return snapshot
    }

    // MARK: - Names of devices no list holds any more

    /// Remembers the names of the devices on `vault`'s list (by id), so the history can still name them once a
    /// change removed them: no list this device keeps holds them then. Names are plaintext in `vault.json` anyway.
    /// The newest 256 are kept (the oldest go first).
    func rememberDeviceNames(_ vault: Vault) {
        let key = Self.deviceNamesKey(vault.vaultId)
        var pairs = ((deviceMemory.object(forKey: key) as? [String]) ?? []).compactMap { line -> (String, String)? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        for e in vault.manifest.devices {
            guard let id = e.id else { continue }
            pairs.removeAll { $0.0 == id }
            pairs.append((id, DeviceName.display(e.name)))
        }
        deviceMemory.set(pairs.suffix(Self.rememberedNamesLimit).map { "\($0.0)\t\($0.1)" }, forKey: key)
    }

    /// At most this many device names are remembered per vault.
    nonisolated static var rememberedNamesLimit: Int { 256 }

    public func rememberedDeviceNames(_ vaultID: UUID) -> [String: String] {
        var out: [String: String] = [:]
        for line in (deviceMemory.object(forKey: Self.deviceNamesKey(vaultID)) as? [String]) ?? [] {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    nonisolated static func deviceNamesKey(_ vaultID: UUID) -> String {
        "Sempere.deviceNames.\(vaultID.uuidString.lowercased())"
    }

    /// `events` with the devices no list here names filled in from `names` (by id).
    nonisolated static func named(_ events: [DeviceHistoryEvent], _ names: [String: String]) -> [DeviceHistoryEvent] {
        func fill(_ r: DeviceRef) -> DeviceRef {
            guard r.name == nil, let n = names[r.id] else { return r }
            var out = r
            out.name = n
            return out
        }
        return events.map { e in
            var e = e
            e.author = fill(e.author)
            e.newHome = e.newHome.map(fill)
            e.removed = e.removed.map(fill)
            return e
        }
    }

    nonisolated static func deviceListSnapshot(_ vault: Vault, now: Date = Date()) -> DeviceListSnapshot {
        let m = vault.manifest
        let this = vault.deviceFingerprint
        let rows = m.devices.map { e -> DeviceRow in
            let addedBy: DeviceRow.AddedBy
            switch e.addedBy {
            case EntryClaim.recovery?: addedBy = .recoveryKit
            case let by? where by == e.id: addedBy = .creation
            case let by?: addedBy = vault.deviceRef(id: by).map { .device(DeviceName.display($0.name ?? "")) } ?? .formerDevice(by)
            case nil: addedBy = .creation
            }
            return DeviceRow(id: e.id ?? "", fingerprint: e.fingerprint, name: DeviceName.display(e.name), kind: e.kind ?? "",
                             added: RFC3339.parse(e.added), addedBy: addedBy, isHome: e.fingerprint == m.home,
                             isThisDevice: e.fingerprint == this,
                             lastSynced: e.id.flatMap { vault.lastSynced(device: $0, now: now) })
        }
        return DeviceListSnapshot(
            devices: rows, recoveryAdded: m.recoveryEntry.flatMap { RFC3339.parse($0.added) },
            passphraseCopy: !vault.passphraseCopyNames().isEmpty, history: vault.deviceHistory(),
            joinRequests: vault.joinRequests().filter { $0.request?.vaultId == vault.vaultId }.count,
            thisIsHome: vault.isHome, homeName: m.homeEntry.map { DeviceName.display($0.name) },
            dropped: vault.droppedEpochs.count)
    }

    // MARK: - Home's changes

    /// Renames a device (on home: design §5.1). The vault is opened again under the new list.
    public func renameDevice(_ id: String, to name: String) async throws {
        guard let start = vault, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireWritableVault()
        let gen = generation
        let lock = vaultWriteLock
        let next = try await offMain { () throws -> Vault in
            var v = start
            try Self.withWriteLock(lock) { try v.renameDevice(id: id, to: name) }
            return v
        }
        try ensureCurrent(gen)
        adoptReopened(next)
        syncSessions.forEach { $0.demand() }
    }

    /// The removal sheet's review of `ids` (design §5.5).
    public func removalReview(_ ids: [String]) async throws -> [RemovalReviewItem] {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        return try await offMain { try vault.removalReview(ids) }
    }

    /// Removes the devices `ids` (on home: design §5.2): every target is synced first (bounded), then a new
    /// epoch. From then on every write here is under the new key.
    public func removeDevices(_ ids: [String]) async throws -> DeviceChangeOutcome {
        try await performDeviceChange { v in try v.removeDevices(ids) }
    }

    /// Makes `id` the device that manages devices (design §5.6 rule 2, a handoff).
    public func makeHome(_ id: String) async throws -> DeviceChangeOutcome {
        try await performDeviceChange { v in try v.handOff(to: id) }
    }

    /// The device review before a kit replacement (design §6.5 step 1).
    public func kitReview() async throws -> [Vault.KitReviewItem] {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        return try await offMain { try vault.kitReview() }
    }

    /// Replaces the recovery kit (on home, after the review and the printed kit: design §6.5). It asks for the device
    /// owner first (`ownerAuthenticator`, step 3): the one list change that needs the owner at the device. A refused
    /// check changes nothing, and so does a vault closed or replaced while the check asks.
    public func replaceRecoveryKit(_ newKit: MLKEM768X25519Identity, keep: Set<String>, remove: Set<String>,
                            oldKit: MLKEM768X25519Identity?, passphrase: String?) async throws -> DeviceChangeOutcome {
        try await checkOwner(for: .replaceRecoveryKit)
        return try await performDeviceChange { v in
            try v.replaceRecoveryKit(newKit, keep: keep, remove: remove, oldRecovery: oldKit, passphrase: passphrase)
        }
    }

    /// Adds (or changes) the passphrase copy of the recovery key (on home, after device-owner authentication).
    /// No device keeps the recovery key, so it comes from the kit: `key` is the pasted or picked recovery key (nil:
    /// none was given). Writes one file in `keys/`; no epoch changes, so nothing is synced first or reopened.
    public func addPassphraseCopy(recoveryKey key: NativeIdentity?, passphrase: String) async throws {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireWritableVault()
        guard case .mlkem768x25519(let recovery)? = key else { throw KeyProblem.recoveryKeyNeeded }
        try await ownerAuthenticator.authenticate(reason: .addPassphraseCopy)
        _ = try await offMain { try vault.addPassphraseCopy(recovery: recovery, passphrase: passphrase) }
    }

    /// The owner check of a change of the open vault (`ownerAuthenticator`), with the vault unlocked and writable
    /// before and after it: on Mac Catalyst the passcode dialog does not block the menus, so another vault may be
    /// opened, or this one closed, while it asks. Then the change is not made (`KeyError.vaultChanged`).
    func checkOwner(for reason: OwnerCheckReason) async throws {
        guard let start = vault, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireWritableVault()
        let gen = generation
        try await ownerAuthenticator.authenticate(reason: reason)
        guard generation == gen, vault?.vaultId == start.vaultId else { throw KeyError.vaultChanged }
        guard phase == .unlocked else { throw KeyError.notUnlocked }
        try requireWritableVault()
    }

    /// The steps every device change shares: a bounded, cancellable two-way run of every target (design §5.2 step 2,
    /// so the change seals what they hold), the editors saved and closed, the change, the vault opened again under
    /// the new epoch (`adoptReopened`), the editors and the runs back. When the change fails, the vault follows the
    /// disk (a change can fail after its `vault.json` is written) and the editors open again all the same.
    func performDeviceChange(_ change: @escaping @Sendable (inout Vault) throws -> EpochChangeReport) async throws
        -> DeviceChangeOutcome {
        guard phase == .unlocked, let before = vault else { throw KeyError.notUnlocked }
        try requireWritableVault()
        rememberDeviceNames(before)
        let gen = generation
        let unreachable = await syncBeforeDeviceChange()
        try ensureCurrent(gen)
        guard let start = vault else { throw KeyError.notUnlocked }
        isChangingKeys = true
        defer { isChangingKeys = false }
        await editGate.acquire()
        defer { editGate.release() }
        let shown = editor?.noteID
        let windows = Array(windowEditors.keys)
        try? await openEditor(for: nil)
        await closeWindowEditors()
        guard generation == gen else { throw KeyError.vaultChanged }
        let outcome: (Vault, EpochChangeReport)
        do {
            outcome = try await offMain { () throws -> (Vault, EpochChangeReport) in
                var v = start
                let r = try change(&v)
                return (v, r)
            }
        } catch {
            if generation == gen {
                let changed = (try? await offMain { Self.manifestChangedOnDisk(start) }) ?? true
                if changed { await reopenUnderSameKeys() }
                isChangingKeys = false
                await reopenEditors(shown: shown, windows: windows)
            }
            throw error
        }
        guard generation == gen else { throw KeyError.vaultChanged }
        adoptReopened(outcome.0)
        isChangingKeys = false
        syncSessions.forEach { $0.demand() }   // the change reaches every target
        await reopenEditors(shown: shown, windows: windows)
        return DeviceChangeOutcome(report: outcome.1, unreachable: unreachable)
    }

    /// The note and note windows a device change closed, open again.
    func reopenEditors(shown: UUID?, windows: [UUID]) async {
        if let shown { try? await openEditor(for: shown) }
        for id in windows { _ = try? await openWindowNote(id) }
    }

    /// The best-effort pull before a device change (design §5.2 step 2): one two-way run of every target of the
    /// open vault, at most `deviceChangeRunBound` each (a run already going is waited for as long, no longer), so
    /// the change seals what other devices uploaded there. `cancelDeviceChangeSync` skips the rest. Returns the
    /// targets it did not reach; their writers catch their files up themselves.
    func syncBeforeDeviceChange() async -> [UnreachableTarget] {
        let cancel = SyncRunCancel()
        deviceChangeCancel = cancel
        isSyncingBeforeChange = true
        defer {
            deviceChangeCancel = nil
            deviceChangeWaitCancel = nil
            isSyncingBeforeChange = false
        }
        var missed: [UnreachableTarget] = []
        let bound = deviceChangeRunBound
        for session in syncSessions {
            let unreached = UnreachableTarget(name: session.targetName, lastSuccess: session.lastSuccess)
            if cancel.isSet { missed.append(unreached); continue }
            if let running = session.currentRun {
                let waiter = Task { _ = await running.value }
                let waited = await Self.waitBounded(waiter, timeout: .milliseconds(Int(bound * 1000))) { [weak self] stop in
                    self?.deviceChangeWaitCancel = stop
                }
                deviceChangeWaitCancel = nil
                if waited != .finished { missed.append(unreached); continue }
            }
            let (ok, _) = await session.runInBackground(maxDuration: bound, cancel: cancel)
            if !ok || cancel.isSet { missed.append(unreached) }
        }
        return missed
    }

    /// The sheet's Cancel while the targets run before a change: the rest are skipped (counted as not reached).
    public func cancelDeviceChangeSync() {
        deviceChangeCancel?.cancel()
        deviceChangeWaitCancel?()
    }

    /// Each target's run before a device change is bounded by this (design §5.2 step 2: 10 seconds).
    nonisolated static var defaultDeviceChangeRunBound: TimeInterval { EpochChangePull.defaultBound }

    // MARK: - Takeover alerts (design §6.3)

    /// Looks for takeovers on the chain this device follows that it has not acknowledged, by another device: the
    /// alert banner (`takeoverAlert`) and a notification. Takeovers are acknowledged by `epochId` (a takeover's
    /// number can be at or below an epoch this device saw before: it beats every home epoch that is not its
    /// ancestor, design §5.6 rule 4). The first time a vault is seen here, the takeovers already on its chain are
    /// acknowledged silently; this device's own takeovers are acknowledged at once. The history is read off the
    /// main actor.
    func checkTakeovers() async {
        guard let vault, phase == .unlocked, !vault.isRecoveryOpen else { return }
        rememberDeviceNames(vault)
        let gen = generation
        let takeovers = await Task.detached(priority: .utility) { vault.deviceHistory().filter { $0.reason == .takeover } }.value
        guard generation == gen, self.vault?.vaultId == vault.vaultId else { return }
        applyTakeovers(takeovers, vault: vault)
    }

    /// `checkTakeovers`' decision for `takeovers` (newest first) of `vault`.
    func applyTakeovers(_ takeovers: [DeviceHistoryEvent], vault: Vault) {
        let key = Self.takeoverAckKey(vault.vaultId)
        let defaults = deviceMemory
        let acknowledged: [String]
        if let stored = defaults.object(forKey: key) as? [String] {
            acknowledged = stored
        } else {
            // First sight (a new install, or one from before the alerts): only the takeovers up to the epoch this
            // device was added at are known history; later ones happened while it was listed and are reported
            // (review of #87 re-check, M1). Stored oldest first, so the limit keeps the newest.
            let added = vault.deviceAddedEpoch ?? Int.max   // unknown: all of them, as before
            acknowledged = takeovers.filter { $0.epoch <= added }.reversed().map { Self.idText($0.epochId) }
            defaults.set(Array(acknowledged.suffix(Self.acknowledgedTakeoversLimit)), forKey: key)
        }
        var updated = acknowledged
        let mine = vault.deviceFingerprint
        let fresh = takeovers.filter { !acknowledged.contains(Self.idText($0.epochId)) }
        let own = fresh.filter { $0.author.fingerprint == mine }
        if !own.isEmpty {
            updated += own.reversed().map { Self.idText($0.epochId) }
            defaults.set(Array(updated.suffix(Self.acknowledgedTakeoversLimit)), forKey: key)
        }
        let others = fresh.filter { $0.author.fingerprint != mine }
        guard let newest = others.first else { return }
        let by = newest.author.name.map(DeviceName.display) ?? rememberedDeviceNames(vault.vaultId)[newest.author.id]
        let alert = TakeoverAlert(vaultID: vault.vaultId, epochIds: others.map(\.epochId),
                                  vaultName: vaultName ?? "", by: by, date: newest.date)
        guard takeoverAlert != alert else { return }
        takeoverAlert = alert
        let notifier = backupNotifier
        Task {
            // The banner is the notice; a notification only where the user already allowed them (no prompt here).
            guard await notifier.isAuthorized() else { return }
            await notifier.schedule(id: "takeover-\(alert.vaultID.uuidString)", at: Date().addingTimeInterval(1),
                                    notice: .takeover(alert))
        }
    }

    /// An epoch id as the acknowledged set stores it (lowercase hex).
    nonisolated static func idText(_ id: Data) -> String { id.map { String(format: "%02x", $0) }.joined() }

    /// At most this many acknowledged takeovers are remembered per vault (the newest).
    nonisolated static var acknowledgedTakeoversLimit: Int { 64 }

    /// The banner's Dismiss: its takeovers are acknowledged on this device.
    public func dismissTakeoverAlert() {
        guard let alert = takeoverAlert else { return }
        let key = Self.takeoverAckKey(alert.vaultID)
        // `epochIds` is newest first; the set is stored oldest first, so the limit keeps the newest.
        let acknowledged = ((deviceMemory.object(forKey: key) as? [String]) ?? []) + alert.epochIds.reversed().map(Self.idText)
        deviceMemory.set(Array(acknowledged.suffix(Self.acknowledgedTakeoversLimit)), forKey: key)
        takeoverAlert = nil
    }

    nonisolated static func takeoverAckKey(_ vaultID: UUID) -> String {
        "Sempere.takeoversAcknowledged.\(vaultID.uuidString.lowercased())"
    }
}
