import Crypto
import Foundation

// What the device list shows (docs/design/key-hierarchy.md §5.5, §6.4; phase KH5), computed once here for the
// app and the CLI: the history of device changes (every epoch's reason, author and date), the review a
// removal shows (the last sync, the devices a former home approved, a kit it replaced), and this device's
// state in the vault (listed, waiting, unlisted, record pending, and since when its sync is held back).

/// A device as this device knows it: its fingerprint and id, and its name when a list this device read
/// names it (devices a change removed may not be on any list it still has).
public struct DeviceRef: Hashable, Sendable {
    public var fingerprint: Data
    /// The first 8 hex digits of the fingerprint.
    public var id: String
    /// Its name (cleaned), nil when no list this device holds names it.
    public var name: String?

    public init(fingerprint: Data, name: String?) {
        self.fingerprint = fingerprint
        id = String(Hex.encode(fingerprint).prefix(8))
        self.name = name
    }

    /// The name, or "device <id>" (English; the app words its own).
    public var display: String { name.map(DeviceName.display) ?? "device \(id)" }
}

/// One device change in the history (design §6.4): an epoch of the chain this device follows.
public struct DeviceHistoryEvent: Hashable, Sendable {
    public var epoch: Int
    public var epochId: Data
    public var reason: EpochReason
    /// When the change was made, from its record (`created`); nil when the record is not here.
    public var date: Date?
    /// Who made it: the parent's home, or for a takeover its new home (signed with the recovery key).
    public var author: DeviceRef
    /// The home after it, when it moved (a handoff, a takeover).
    public var newHome: DeviceRef?
    /// The devices it removed, computed from the signed lists (design §4.1).
    public var removed: [DeviceRef]
}

/// A device a removal would remove, with what the sheet warns about (design §5.5).
public struct RemovalReviewItem: Hashable, Sendable {
    public var device: EpochKeyEntry
    /// When it last completed a two-way sync (its own summaries file), nil when unknown.
    public var lastSynced: Date?
    /// When `lastSynced` is unknown because its summaries file is still sealed under an earlier epoch: it has not
    /// completed a sync since the current device change, made at this date. Nil otherwise.
    public var notSyncedSinceChange: Date?
    /// True when its last sync was longer ago than the bound, or is unknown (and, when it is only known not to be
    /// since the current change, that change is older than the bound): its later changes will not reach the vault.
    public var stale: Bool
    /// Listed devices it approved (`addedBy` its id): while it was home, before a handoff. The sheet offers
    /// to remove them too, checked when the device is marked lost or stolen. Never the current home.
    public var approved: [EpochKeyEntry]
    /// It made the current recovery kit (the last `recovery` or `reencrypt` epoch of the chain) while it was home:
    /// the sheet suggests replacing the kit again (design §5.2.1). A kit it made that a later replacement retired
    /// does not count.
    public var replacedKit: Bool
}

/// This device's state in the vault (design §4.3, §5.5; `sempere devices status`).
public struct DeviceSyncStatus: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        /// On the list it follows, nothing held back.
        case listed
        /// A sync met a later device list it cannot verify yet: it writes here, uploads nothing new.
        case waiting
        /// The newest list it verified does not hold it: it writes nothing and keeps pulling.
        case unlisted
        /// It follows a change whose record has not arrived: files from before it are not read yet.
        case recordPending = "record-pending"
    }

    public var state: State
    /// Why (English, from the engine), nil when listed.
    public var notice: String?
    /// While waiting: when this device first met the change it waits for (its oldest anchored sighting).
    public var heldSince: Date?

    public init(state: State, notice: String? = nil, heldSince: Date? = nil) {
        self.state = state; self.notice = notice; self.heldSince = heldSince
    }

    /// True once held back for longer than `bound` (the owner's "about a day", review of #86).
    public func heldLong(now: Date = Date(), bound: TimeInterval = DeviceSyncStatus.heldWarning) -> Bool {
        guard let heldSince else { return false }
        return now.timeIntervalSince(heldSince) > bound
    }

    /// A day: past it, a held-back sync is reported (the CLI warns, the app shows a banner).
    public static let heldWarning: TimeInterval = 86_400
}

extension Vault {
    // MARK: - Names

    /// A device by fingerprint, named from the current list, else this device's trust record.
    public func deviceRef(_ fingerprint: Data) -> DeviceRef {
        if let e = manifest.keys.first(where: { $0.role == .device && $0.fingerprint == fingerprint }) {
            return DeviceRef(fingerprint: fingerprint, name: DeviceName.clean(e.name))
        }
        let record = (try? trustStore?.record(for: vaultId)) ?? nil
        let known = record?.list.first { e in
            guard e.role == EpochKeyEntry.Role.device.rawValue, let sign = e.sign else { return false }
            return KeyFingerprint.device(key: e.key, signP256: sign.p256Hex, signMLDSA65: sign.mldsa65Hex) == fingerprint
        }
        return DeviceRef(fingerprint: fingerprint, name: known.map { DeviceName.clean($0.name) })
    }

    /// The device whose id is `id` on the current list (an `addedBy`), named; nil for `recovery` or an id no
    /// listed device has.
    public func deviceRef(id: String) -> DeviceRef? {
        guard id != EntryClaim.recovery, let e = manifest.devices.first(where: { $0.id == id }) else { return nil }
        return DeviceRef(fingerprint: e.fingerprint, name: DeviceName.clean(e.name))
    }

    // MARK: - History (design §6.4)

    /// Every device change of the chain this device follows, newest first: reason, author, date, the new home
    /// and the devices removed. Dates come from the epoch records, read down the chain under the keys each
    /// gives (a record that is missing leaves its date and those below unknown). Needs the key.
    public func deviceHistory() -> [DeviceHistoryEvent] {
        guard canRead else { return [] }
        let dates = recordDates()
        if let chain = verifiedChain {
            var out: [DeviceHistoryEvent] = []
            for (i, e) in chain.entries.enumerated() {
                let reason = EpochReason(rawValue: e.reason) ?? .remove
                let previousHome = i > 0 ? chain.entries[i - 1].home : nil
                let moved = previousHome.map { $0 != e.home } ?? false
                let removed = chain.removals.indices.contains(i) ? chain.removals[i] : []
                out.append(DeviceHistoryEvent(
                    epoch: e.epoch, epochId: e.epochId, reason: reason, date: dates[e.epoch],
                    author: deviceRef(e.author.fingerprint), newHome: moved ? deviceRef(e.home) : nil,
                    removed: removed.subtracting([e.recovery]).sorted { $0.lexicographicallyPrecedes($1) }.map { deviceRef($0) }))
            }
            return out.reversed()
        }
        // Epoch 1 has no chain to verify above it: the creation.
        return [DeviceHistoryEvent(epoch: manifest.epoch, epochId: manifest.epochId,
                                   reason: EpochReason(rawValue: manifest.epochReason) ?? .create,
                                   date: dates[manifest.epoch] ?? created, author: deviceRef(manifest.home), newHome: nil, removed: [])]
    }

    /// Takeovers on the chain above epoch `after`, newest first (the alerts of design §6.3).
    public func takeovers(after epoch: Int) -> [DeviceHistoryEvent] {
        deviceHistory().filter { $0.reason == .takeover && $0.epoch > epoch }
    }

    /// The `created` date of each epoch's record, by epoch number: the current record under the current key,
    /// then each earlier one under the key its child gives, as long as each hashes to its link.
    func recordDates() -> [Int: Date] {
        guard let secret else { return [:] }
        var out: [Int: Date] = [:]
        var key = secret
        var epoch = manifest.epoch
        var name = manifest.epochRecord
        var expected: Data? = manifest.epochRecordHash
        while epoch >= 1 {
            guard let hash = expected,
                  let data = try? (Self.readsWithoutLinks(url)
                    ? BoundedRead.contents(under: url, name, maxBytes: EpochRecord.maxBytes)
                    : BoundedRead.contents(of: url.appendingPathComponent(name), maxBytes: EpochRecord.maxBytes)),
                  Data(SHA256.hash(data: data)) == hash,
                  let record = try? EpochRecord.open(data, key: key, vaultId: vaultId, epoch: epoch) else { break }
            out[epoch] = RFC3339.parse(record.created)
            guard let parent = record.parent, let pk = parent.key, parent.epoch == epoch - 1 else { break }
            key = pk
            epoch -= 1
            name = Self.epochsName + "/" + EpochRecord.fileName(epoch: epoch, epochId: pk.epochId)
            expected = parent.recordHash
        }
        return out
    }

    // MARK: - Removal review (design §5.5)

    /// The devices `ids` (ids or unique prefixes of 4+ hex digits) as a removal sheet shows them: last sync
    /// (stale past `staleAfter`, or unknown), the devices each approved, and whether it replaced the kit.
    public func removalReview(_ ids: [String], now: Date = Date(), staleAfter: TimeInterval = 86_400) throws -> [RemovalReviewItem] {
        let chain = verifiedChain?.entries ?? []
        return try ids.map { q in
            let d = try resolveDevice(q)
            let last = d.id.flatMap { lastSynced(device: $0, now: now) }
            // Never the home itself: it cannot remove itself (design §5.2).
            let approved = manifest.devices.filter {
                $0.addedBy == d.id && $0.fingerprint != d.fingerprint && $0.fingerprint != manifest.home && d.id != nil
            }
            let currentKit = chain.last {
                $0.reason == EpochReason.recovery.rawValue || $0.reason == EpochReason.reencrypt.rawValue
            }
            let kit = currentKit?.author.fingerprint == d.fingerprint && currentKit?.recovery == manifest.recoveryFingerprint
            var sinceChange: Date?
            if last == nil, let id = d.id, let summaryEpoch = summariesEpoch(device: id), summaryEpoch < manifest.epoch {
                sinceChange = recordDates()[manifest.epoch] ?? Date.distantPast
            }
            let stale: Bool
            if let last { stale = now.timeIntervalSince(last) > staleAfter } else if let sinceChange {
                stale = now.timeIntervalSince(sinceChange) > staleAfter
            } else { stale = true }
            return RemovalReviewItem(device: d, lastSynced: last, notSyncedSinceChange: sinceChange, stale: stale,
                                     approved: approved, replacedKit: kit)
        }
    }

    /// The epoch the device `id`'s summaries file is sealed under, without its key; nil when it has none.
    func summariesEpoch(device id: String) -> Int? {
        guard let device = DeviceID(id) else { return nil }
        let url = devicePublishedSummariesURL(device)
        guard FileIO.exists(url), let data = try? FileIO.read(url, maxBytes: PublishedSummaries.maxFileBytes),
              let (sealed, _) = PublishedSummaries.split(data) else { return nil }
        return PublishedSummaries.sealedEpoch(sealed)
    }

    /// The `epochId`s of the takeovers on the chain this device follows (the alerts of design §6.3 acknowledge
    /// takeovers by id: a takeover's epoch number can be at or below one this device saw before, since it beats
    /// every home epoch that is not its ancestor).
    public func takeoverEpochIds() -> [Data] {
        (verifiedChain?.entries ?? []).filter { $0.reason == EpochReason.takeover.rawValue }.map(\.epochId)
    }

    // MARK: - This device's state (design §4.3, §5.5)

    /// Listed, waiting (since when), unlisted or record pending, as `sempere devices status` prints it.
    public var deviceSyncStatus: DeviceSyncStatus {
        if let n = unlistedNotice { return DeviceSyncStatus(state: .unlisted, notice: n) }
        if let n = waitingNotice {
            let since = sightings().filter { isAnchoredSighting($0) }.map(\.seen).min()
            return DeviceSyncStatus(state: .waiting, notice: n, heldSince: since)
        }
        if isRecordPending {
            return DeviceSyncStatus(state: .recordPending, notice: "waiting for the device-change record \(manifest.epochRecord); "
                + "files from before it are not read yet")
        }
        return DeviceSyncStatus(state: .listed)
    }

    /// While unlisted (design §5.5): the newest anchored sighting's change, as the screen names it: who made
    /// it (the epoch's author, named from this device's own list) and when this device first saw it.
    public var removalSighting: (author: DeviceRef?, seen: Date)? {
        guard unlistedNotice != nil,
              let s = sightings().filter({ isAnchoredSighting($0) }).max(by: { $0.epoch < $1.epoch }) else { return nil }
        let author = (try? Self.readManifest(s.manifest)).flatMap { deviceRef(id: $0.epochAuthor) }
        return (author, s.seen)
    }

    // MARK: - Repair: the bulk Keep (design §5.4)

    /// Set-aside files under an epoch a takeover dropped whose path and bytes this device's ledger holds: its own
    /// writes, which Repair's bulk Keep puts back under the current key (`LedgerRule.keepable`).
    public func ownDroppedSetAside() -> [SetAsideItem] {
        guard let setAsideStore, let ledger, let entries = try? ledger.entries() else { return [] }
        let items = setAsideStore.items(vaultId: vaultId).filter { $0.reason == .dropped }
        func ref(_ path: String, _ sha: String, _ epochId: String?) -> LedgerRule.FileRef? {
            guard let s = Hex.decode(sha), let e = epochId.flatMap({ Hex.decode($0) }) else { return nil }
            return LedgerRule.FileRef(path: path, sha256: s, epochId: e)
        }
        let set = items.compactMap { ref($0.path, $0.sha256, $0.epochId) }
        let mine = entries.compactMap { ref($0.path, $0.sha256, $0.epochId) }
        let keep = Set(LedgerRule.keepable(setAside: set, ledger: mine, dropped: Set(set.map(\.epochId))))
        return items.filter { i in ref(i.path, i.sha256, i.epochId).map { keep.contains($0) } ?? false }
    }
}
