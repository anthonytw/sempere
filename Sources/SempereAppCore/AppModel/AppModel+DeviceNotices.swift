import Foundation
import Sempere
import SempereSync

// This device's place in the vault (key-hierarchy design §4.3, §5.5, §5.6; KH5): the
// banners over the note list (not on the newest device list; sync held back for more than a day; a home
// conflict), the unlisted screen's facts (who removed it, its own changes no target holds), and Repair's
// set-aside files and sightings (design §5.8; review of #86: forget is detached-only unless the user chooses
// all, with the warning). The banners' words and symbols are the app's (`DeviceNotice.text`, `symbol`).

/// A banner over the note list.
public enum DeviceNotice: Hashable, Identifiable, Sendable {
    /// This device is not on the newest device list it verified (design §5.5): it writes nothing.
    case unlisted
    /// A sync met a later device list it cannot verify, more than a day ago: it uploads nothing new until the
    /// home device's change (its record) reaches it.
    case heldBack(since: Date)
    /// Two device lists this device does not follow either of (the home device signed two changes, or the
    /// lists do not contain each other): it stays where it is until a takeover settles it (design §5.6).
    case homeConflict
    /// A takeover dropped device changes this device had made, and with them its removal of these devices (by
    /// name), which are on the device list again (offline audit P16). Home may remove them again; another device
    /// is told to ask home.
    case removalsUndone(names: [String], home: Bool)

    public var id: String {
        switch self {
        case .unlisted: return "unlisted"
        case .heldBack: return "held"
        case .homeConflict: return "conflict"
        case .removalsUndone: return "undone"
        }
    }
}

/// A device this device had removed whose removal a takeover undid (offline audit P16): it is on the list again.
public struct UndoneRemoval: Hashable, Sendable {
    /// The device's id (8 hex digits).
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The store vault's record of removals a takeover undid (`AppModel.undoneRemovalsSource`); none for a vault
    /// elsewhere.
    public static func recorded(_ vault: Vault) -> [UndoneRemoval] {
        guard let url = UndoneRemovalsRecord.url(storeVault: vault.url, vaultId: vault.vaultId) else { return [] }
        return UndoneRemovalsRecord.load(url).map { UndoneRemoval(id: $0.id, name: $0.name.map(DeviceName.display) ?? $0.id) }
    }
}

/// The unlisted screen's facts (design §5.5).
public struct UnlistedFacts: Equatable, Sendable {
    /// Who made the change that removed this device (nil: no list here names it).
    public var by: String?
    /// When this device first saw it.
    public var seen: Date?
    /// This device's own files that no target holds (its write ledger's).
    public var unsynced: [String]

    public init(by: String? = nil, seen: Date? = nil, unsynced: [String]) {
        self.by = by
        self.seen = seen
        self.unsynced = unsynced
    }

    /// Voice notes recorded here that are not in a note yet (`inbox/` captures): only the files keep them.
    public var captures: Int { unsynced.filter { $0.hasPrefix("inbox/") }.count }

    /// The notes those files belong to.
    public var notes: [UUID] {
        var seen = Set<UUID>(), out: [UUID] = []
        for p in unsynced {
            let parts = p.split(separator: "/")
            guard parts.count >= 3, parts[0] == "notes", let id = UUID(uuidString: String(parts[1])), seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }
}

/// One sighting as Repair lists it (`Vault.sightings`).
public struct SightingRow: Identifiable, Equatable, Sendable {
    public var epoch: Int
    public var epochId: Data
    /// Its parent is an epoch this device verified: it holds every sync back (a real change whose record has not
    /// arrived, or this device's removal). Detached ones (nothing verifies them) hold back only the targets that
    /// show them.
    public var anchored: Bool
    public var sources: [String]
    public var seen: Date
    public var id: Data { epochId }

    public init(epoch: Int, epochId: Data, anchored: Bool, sources: [String], seen: Date) {
        self.epoch = epoch
        self.epochId = epochId
        self.anchored = anchored
        self.sources = sources
        self.seen = seen
    }
}

extension AppModelCore {
    // MARK: - Banners

    /// The banners for the open vault, from its state at open and its targets' last runs.
    public var deviceNotices: [DeviceNotice] {
        guard phase == .unlocked, let vault, !vault.isRecoveryOpen else { return [] }
        var out: [DeviceNotice] = []
        let reports = syncSessions.compactMap { $0.lastReport?.epoch }
        if unlistedNotice != nil {
            out.append(.unlisted)
            return out
        }
        let since = ([heldSinceAtOpen] + reports.map(\.heldSince)).compactMap { $0 }.min()
        if let since, DeviceSyncStatus(state: .waiting, heldSince: since).heldLong(now: deviceNoticeNow()) {
            out.append(.heldBack(since: since))
        }
        if reports.contains(where: { $0.conflict != nil }) { out.append(.homeConflict) }
        let undone = undoneRemovals
        if !undone.isEmpty { out.append(.removalsUndone(names: undone.map(\.name), home: vault.isHome)) }
        return out
    }

    /// The devices whose removal by this device a takeover undid and that are still listed (offline audit P16).
    public var undoneRemovals: [UndoneRemoval] {
        guard phase == .unlocked, let vault, !vault.isRecoveryOpen else { return [] }
        let listed = Set(vault.manifest.devices.compactMap(\.id))
        return undoneRemovalsSource(vault).filter { listed.contains($0.id) }
    }

    /// True when this device is not on the newest device list (design §5.5): every write is refused.
    public var isUnlisted: Bool { unlistedNotice != nil }

    /// After a two-way run: when a target reported this device unlisted and the open vault does not know it yet,
    /// the vault is opened again, so its own refusal of writes and the unlisted screen's facts follow.
    public func reopenIfUnlisted() async {
        guard phase == .unlocked, !isChangingKeys, let vault, vault.unlistedNotice == nil,
              syncSessions.contains(where: { $0.lastReport?.epoch?.unlisted != nil }) else { return }
        await reopenUnderSameKeys()
    }

    // MARK: - The unlisted screen

    /// Who removed this device, when it saw it, and its own changes no target holds.
    public func unlistedFacts() async -> UnlistedFacts {
        guard let vault else { return UnlistedFacts(unsynced: []) }
        let store = syncStore
        let targets = store.targets.targets(of: vault.vaultId).map { t -> (state: URL, directory: URL) in
            let state = store.targets.stateURL(t.id, of: vault.vaultId)
            return (state, state.deletingLastPathComponent())
        }
        return await Task.detached(priority: .userInitiated) {
            let sighting = vault.removalSighting
            // A file only written into iCloud Drive's local folder is held by no target yet (offline audit P15).
            let unsynced = (try? ProviderUploads.unsyncedPaths(vault: vault, targets: targets)) ?? []
            return UnlistedFacts(by: sighting?.author?.name.map(DeviceName.display), seen: sighting?.seen, unsynced: unsynced)
        }.value
    }

    /// Copies this device's own files that no target holds, as they are (encrypted, under their vault paths), into
    /// `folder` the user picked: the unlisted screen's Save Files (everything, voice notes not yet in a note
    /// included; review of #87, M3). They open with this vault's keys (`sempere`, or the kit and stock `age`).
    public func exportUnsyncedFiles(_ paths: [String], to folder: URL) async throws -> Int {
        guard let vault else { throw ModelError.noVaultOpen }
        let source = vault.url
        let bookmarks = services.bookmarks
        return try await offMain {
            try bookmarks.withAccess(to: folder) {
                let dir = folder.appendingPathComponent("Sempere unsynced \(RFC3339.string(Date()).prefix(10))", isDirectory: true)
                return try UnsyncedChanges.export(paths, from: source, to: dir).count
            }
        }
    }

    // MARK: - Repair: set-aside files (design §5.8)

    /// The set-aside files of the open vault on this device, each with whether it is superseded.
    public func setAsideItems() async -> [SetAsideStatus] {
        guard let vault, phase == .unlocked else { return [] }
        return await Task.detached(priority: .userInitiated) { vault.setAsideReport() }.value
    }

    /// This device's own files under changes a takeover dropped (the bulk Keep, design §5.4).
    public func ownDroppedSetAside() async -> [SetAsideItem] {
        guard let vault, phase == .unlocked else { return [] }
        return await Task.detached(priority: .userInitiated) { vault.ownDroppedSetAside() }.value
    }

    /// Keeps `items` in the vault, re-encrypted under the current key (on the user's word: they may come from a
    /// removed device). Each item stays set aside until cleared.
    public func keepSetAside(_ items: [SetAsideItem]) async throws {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireWritableVault()
        let lock = vaultWriteLock
        try await offMain { try Self.withWriteLock(lock) { for item in items { try vault.keepSetAside(item) } } }
        let ids = Set(items.compactMap { item -> UUID? in
            let parts = item.path.split(separator: "/")
            return parts.count >= 2 && parts[0] == "notes" ? UUID(uuidString: String(parts[1])) : nil
        })
        if !ids.isEmpty { _ = try? await reconcile(scope: ids) }
        syncSessions.forEach { $0.demand() }
    }

    /// Copies `items` as they are (age files) under their vault paths into `folder` (the user picked it).
    public func exportSetAside(_ items: [SetAsideItem], to folder: URL) async throws -> Int {
        guard let vault else { throw KeyError.notUnlocked }
        let bookmarks = services.bookmarks
        return try await offMain {
            try bookmarks.withAccess(to: folder) {
                for item in items { try vault.exportSetAside(item, to: folder) }
                return items.count
            }
        }
    }

    /// Deletes `items` from this device's set-aside store (the user's choice; "Clear Superseded").
    public func clearSetAside(_ items: [SetAsideItem]) async throws {
        guard let store = vault?.setAsideStore else { return }
        try await offMain { for item in items { try store.remove(item) } }
    }

    // MARK: - Repair: sightings (KH4 §16.10)

    /// The device lists a sync met and this device did not take (as last read, `refreshDeviceState`).
    public var sightingRows: [SightingRow] { sightingRowsState }

    /// Reads, off the main actor, since when this device's sync is held back and its sightings (each judged
    /// anchored or detached, which can verify signatures): after an unlock, a reopen, a run and a Forget.
    public func refreshDeviceState() async {
        guard let vault, phase == .unlocked else { return }
        let gen = generation
        let (since, rows) = await Task.detached(priority: .utility) { () -> (Date?, [SightingRow]) in
            let rows = vault.sightings().map {
                SightingRow(epoch: $0.epoch, epochId: $0.epochId, anchored: vault.isAnchoredSighting($0), sources: $0.sources,
                            seen: $0.seen)
            }.sorted { $0.epoch > $1.epoch }
            return (vault.deviceSyncStatus.heldSince, rows)
        }.value
        guard generation == gen, self.vault?.vaultId == vault.vaultId else { return }
        heldSinceAtOpen = since
        sightingRowsState = rows
    }

    /// Forgets the detached sightings, or with `anchoredToo` every one (the user chose it after the warning): a
    /// removal marker among them, after which this device writes and uploads again until a sync meets the change
    /// again. The vault is opened again so its state follows. Returns how many were forgotten.
    @discardableResult
    public func forgetSightings(anchoredToo: Bool) async throws -> Int {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        let gen = generation
        let n = try await offMain { try vault.forgetSightings(anchoredToo: anchoredToo) }
        try ensureCurrent(gen)
        if anchoredToo, n > 0 { await reopenUnderSameKeys() }
        await refreshDeviceState()
        syncSessions.forEach { $0.demand() }
        return n
    }

    /// Opens the vault again with the keys it was unlocked with (its state at open follows what changed in the
    /// trust store), as after a list change from elsewhere.
    public func reopenUnderSameKeys() async {
        guard let start = vault, phase == .unlocked else { return }
        let keys = unlockKeys
        let trust = keys.root == nil ? self.trust : nil
        let stores = writeStores
        let gen = generation
        let id = start.vaultId, url = start.url
        guard let next = try? await offMain({
            try Vault.open(at: url, identities: keys.identities, signing: keys.signing, trust: trust, root: keys.root,
                           ledger: stores?.ledger(for: id), setAside: stores?.setAside)
        }), generation == gen else { return }
        adoptReopened(next)
    }
}
