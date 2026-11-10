import Foundation
import Sempere
@_exported import SempereCapture

// The logic of quick voice notes (docs/quick-capture.md, format.md §11) that needs no platform service: the stored
// profile and where it lives, the errors, which segment files a recording folder holds and what a seal may do with
// them, and where a sealed capture goes (the vault's inbox, else the local queue). The state machine that calls these is
// `QuickCapture` (`QuickCapture/`); the recorder, the audio session, the Live Activity, the intents, the Keychain and
// file protection stay in the app (`QuickCapture+App.swift`). No text: the app words the errors (`QuickCapture+Text.swift`).

/// What this device keeps for quick voice notes (docs/quick-capture.md):
/// the vault's capture profile (public recipients and the capture key, never
/// the identity or the vault secret) and whether voice notes are transcribed
/// here. The vault is found by its id in the in-app store (`CaptureDelivery`). A profile
/// stored by 1.0.0 also has a `bookmark` of the vault folder, which decoding ignores.
public struct StoredCaptureProfile: Codable, Equatable, Sendable {
    public var profile: CaptureProfile
    public var vaultName: String
    /// Transcribe voice notes on this device when they stop.
    public var transcribe: Bool
    /// This device is not on the vault's newest device list (key-hierarchy design §5.5; review of #87, R1): no
    /// new voice note starts, while a recording in progress, leftovers and the queue are still sealed into
    /// `inbox/` with ledger entries, so the unlisted screen's Save Files covers them. Lifted, keeping the
    /// notebook, once the device is listed again. Absent means not suspended.
    public var suspended: Bool? = nil

    public init(profile: CaptureProfile, vaultName: String, transcribe: Bool, suspended: Bool? = nil) {
        self.profile = profile
        self.vaultName = vaultName
        self.transcribe = transcribe
        self.suspended = suspended
    }
}

/// Where the profile lives: the Keychain in the app (`KeychainCaptureProfileStore`,
/// `AfterFirstUnlockThisDeviceOnly`), memory in tests.
public protocol CaptureProfileStore: Sendable {
    func load() throws -> StoredCaptureProfile?
    func save(_ profile: StoredCaptureProfile) throws
    func delete() throws
}

/// `CaptureProfileStore` in memory (tests).
public final class MemoryCaptureProfileStore: CaptureProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredCaptureProfile?
    public init() {}
    public func load() throws -> StoredCaptureProfile? { lock.withLock { value } }
    public func save(_ profile: StoredCaptureProfile) throws { lock.withLock { value = profile } }
    public func delete() throws { lock.withLock { value = nil } }
}

public enum QuickCaptureError: Error, Equatable, Sendable {
    case notSetUp
    /// A profile may be stored but could not be read (the Keychain before the
    /// first unlock after a restart, or an item that does not decode).
    case profileUnreadable
    case microphoneDenied
    /// iOS ends a recording started by an intent (widget, Control Center, Action
    /// button) that shows no Live Activity, so none starts while they are off.
    case liveActivitiesOff
    case alreadyRecording
    case notRecording
    /// iOS did not start the recording's Live Activity (`Activity.request` threw) while the app was
    /// not in front: an `AudioRecordingIntent` records in the background only while one shows, so the
    /// recorder is not started there (the intent continues in the app instead).
    case liveActivityRefused(String)
    /// The intent could not continue in the app (`continueInForeground` threw: iOS refused, or the
    /// device was not unlocked) after a refused background start.
    case couldNotOpenApp(String)
    /// The device has not been unlocked since it restarted: the profile (and the folder the audio
    /// would go to) cannot be read until then (docs/quick-capture.md "Threat model").
    case beforeFirstUnlock
    /// The microphone permission read as not granted while the app was not in front (a process
    /// Siri or a widget launched, maybe before the first unlock after a restart, which cannot show
    /// the permission prompt): checked again with the app in front instead of refusing. TestFlight
    /// 1.0.0 (6), iPhone: after a restart Siri said Sempere was not allowed to use the microphone.
    case microphoneUnconfirmed
    /// The profile is suspended (`StoredCaptureProfile.suspended`): this device was removed from the vault's
    /// device list, so a new voice note could never reach the vault.
    case notOnDeviceList
}

/// A system permission that keeps voice notes (widgets, Lock Screen, Control Center, Action button,
/// Siri) from recording, shown in Settings ▸ Quick Voice Notes with a way to turn it on.
public enum VoiceNoteBlocker: Hashable, Sendable {
    case liveActivitiesOff
    case microphoneDenied

    public static func current(liveActivitiesEnabled: Bool, microphoneDenied: Bool) -> [VoiceNoteBlocker] {
        var out: [VoiceNoteBlocker] = []
        if !liveActivitiesEnabled { out.append(.liveActivitiesOff) }
        if microphoneDenied { out.append(.microphoneDenied) }
        return out
    }
}

// MARK: - Delivery

/// Where a sealed voice note goes: the profile's vault's `inbox/` (its in-app copy, which the store holds by the vault's
/// id), or this device's queue when that folder cannot be reached, is not the profile's
/// vault, or is read-only (a newer format: this version writes nothing into its `inbox/`, format.md §7.3; security
/// review 2026-10, N2). Each file is recorded in its vault's write ledger before it is placed in the inbox
/// (key-hierarchy design §5.4, §5.7): never placed unrecorded.
public struct CaptureDelivery: Sendable {
    /// Where it went.
    public enum Destination: Equatable, Sendable { case vault, queued }

    /// Sealed captures waiting for the vault folder, per vault id.
    var queueRoot: URL
    /// The in-app vault store: a voice note for a store vault goes straight into its inbox, found by vault id,
    /// open or not (docs/design/device-first-sync.md §5.3).
    var vaultStore: VaultStore?
    /// Holds the vault folder's scope while it is written (the app's security-scoped bookmarks).
    var bookmarks: any FolderBookmarks
    /// The write ledger of a vault (this device's, `DeviceWriteStores`); nil records nothing (tests).
    var ledger: (@Sendable (UUID) -> any WriteLedgerStore)?
    /// Called with the vault id after captures were written into its inbox (the app posts
    /// `QuickCapture.deliveredNotification`, so a synced copy runs soon).
    var delivered: @Sendable (UUID) -> Void

    init(queueRoot: URL, vaultStore: VaultStore?, bookmarks: any FolderBookmarks,
                ledger: (@Sendable (UUID) -> any WriteLedgerStore)?, delivered: @escaping @Sendable (UUID) -> Void) {
        self.queueRoot = queueRoot
        self.vaultStore = vaultStore
        self.bookmarks = bookmarks
        self.ledger = ledger
        self.delivered = delivered
    }

    /// Writes `sealed` into the vault's inbox, or into the local queue (`deliver`'s rules above).
    func deliver(_ sealed: SealedCapture, _ stored: StoredCaptureProfile) throws -> Destination {
        if let url = vaultFolder(stored) {
            let placed = bookmarks.withAccess(to: url) { () -> Bool in
                guard Self.acceptsCaptures(at: url, vaultId: stored.profile.vaultId) else { return false }
                let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
                do {
                    try record(sealed, stored.profile)   // intent first: never placed unrecorded
                    try CaptureWriter.store(sealed, in: inbox)
                    return true
                } catch {
                    return false   // Not reachable now: queued below.
                }
            }
            if placed {
                delivered(stored.profile.vaultId)
                return .vault
            }
        }
        // `WatchQueue` keeps the layout (the epoch sidecar first, durably, then the file): one flush serves a voice note of
        // this device and a Watch note of any vault, and a crash leaves a sidecar without a file (ignored), never a file
        // without its epoch. The flush records that epoch, never a newer profile's (M4).
        try WatchQueue.store(sealed, in: queueFolder(stored.profile.vaultId))
        return .queued
    }

    /// `<queued file>.epoch`: "<epoch> <epoch id hex>", the epoch of the profile that sealed it.
    static func epochSidecar(_ file: URL) -> URL { WatchQueue.epochSidecar(file) }

    /// The epoch a queued file was sealed under, from its sidecar.
    static func queuedEpoch(_ file: URL) -> (Int, Data)? {
        guard let data = try? BoundedRead.contents(of: epochSidecar(file), maxBytes: 256),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count == 2, let e = Int(parts[0]) else { return nil }
        let hex: [UInt8] = Array(parts[1].utf8)
        guard hex.count == 64 else { return nil }
        var id = Data()
        for i in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(decoding: hex[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            id.append(byte)
        }
        return (e, id)
    }

    /// Records `sealed` in the write ledger of the profile's vault (design §5.4); nothing without `ledger`.
    func record(_ sealed: SealedCapture, _ profile: CaptureProfile) throws {
        guard let ledger else { return }
        try CaptureWriter(profile: profile).record(sealed, in: ledger(profile.vaultId))
    }

    /// True when the folder at `url` is vault `vaultId` and this version may
    /// write into its inbox: not one marked as written by a newer version
    /// (its `format` or `features`, format.md §7.3). Checked from `vault.json`
    /// alone, without a key.
    static func acceptsCaptures(at url: URL, vaultId: UUID) -> Bool {
        guard let vault = try? Vault.open(at: url) else { return false }
        return vault.vaultId == vaultId && !vault.isReadOnly
    }

    func queueFolder(_ vault: UUID) -> URL { WatchQueue.folder(queueRoot, vault: vault) }

    /// How many captures wait in the queue of any vault but `vault` (Settings: "N Watch notes waiting for another vault").
    func queuedCount(excluding vault: UUID?) -> Int {
        let fm = FileManager.default
        let skip = vault?.uuidString.lowercased()
        var count = 0
        for folder in (try? fm.contentsOfDirectory(atPath: queueRoot.path)) ?? [] where folder.lowercased() != skip {
            let names = (try? fm.contentsOfDirectory(atPath: queueRoot.appendingPathComponent(folder).path)) ?? []
            count += names.filter { CaptureFile.parse(name: $0)?.kind == .capture }.count
        }
        return count
    }

    /// The folder of the profile's vault: its in-app copy, found by id in the store (every vault the app opens is one,
    /// `VaultStore`), so a moved store does not matter. Nil without a store or a copy: the capture is queued.
    func vaultFolder(_ stored: StoredCaptureProfile) -> URL? {
        vaultStore?.entry(id: stored.profile.vaultId)?.url
    }

    /// Moves queued captures of `vaultId` into the vault at `vaultURL`
    /// (sealed already: plain file moves), each inside a write `files` coordinates (iCloud Drive). Returns how
    /// many moved. Nothing moves into a read-only vault (format.md §7.3): they stay queued.
    ///
    /// - Parameter profile: a profile of this vault, to record them in its ledger (design §5.4) under the epoch
    ///   each was sealed with (its sidecar: a Watch note of any vault has one, so it needs no profile of its vault; a file
    ///   queued before sidecars existed takes the profile's); with a ledger, no sidecar and no such profile a file stays
    ///   queued, never placed unrecorded.
    @discardableResult
    func flushQueue(into vaultURL: URL, vaultId: UUID, profile: CaptureProfile?,
                           files: (any FileCoordinating)?) -> Int {
        guard Self.acceptsCaptures(at: vaultURL, vaultId: vaultId) else { return 0 }
        let dir = queueFolder(vaultId)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { CaptureFile.parse(name: $0) != nil }
        let inbox = vaultURL.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        var moved = 0
        for name in names {
            let file = dir.appendingPathComponent(name)
            guard let kind = CaptureFile.parse(name: name)?.kind,
                  let data = try? BoundedRead.contents(of: file, maxBytes: CaptureFile.maxSealedBytes(kind)) else { continue }
            do {
                let epoch = Self.queuedEpoch(file)
                let sealed = SealedCapture(name: name, data: data, epoch: epoch?.0, epochId: epoch?.1)
                if let ledger {
                    if epoch != nil {
                        try WatchLedger.record(sealed, in: ledger(vaultId))   // its own epoch: no profile needed
                    } else {
                        guard let profile, profile.vaultId == vaultId else { continue }
                        try record(sealed, profile)
                    }
                }
                if let files {
                    try files.coordinateWriting(inbox) { try CaptureWriter.store(sealed, in: inbox) }
                } else {
                    try CaptureWriter.store(sealed, in: inbox)
                }
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: Self.epochSidecar(file))
                moved += 1
            } catch {
                continue
            }
        }
        return moved
    }

    /// Moves queued captures into the stored profile's vault when its folder can be reached (uncoordinated: the
    /// app became active). Returns how many moved.
    @discardableResult
    func flushQueue(of stored: StoredCaptureProfile) -> Int {
        guard let url = vaultFolder(stored) else { return 0 }
        let moved = bookmarks.withAccess(to: url) {
            flushQueue(into: url, vaultId: stored.profile.vaultId, profile: stored.profile, files: nil)
        }
        if moved > 0 { delivered(stored.profile.vaultId) }
        return moved
    }
}
