import Foundation
import Sempere

// The logic of quick voice notes (docs/quick-capture.md, format.md §11) that needs no platform service: the stored
// profile and where it lives, the errors, which segment files a recording folder holds and what a seal may do with
// them, and where a sealed capture goes (the vault's inbox, else the local queue). The state machine that calls these is
// `QuickCapture` (`QuickCapture/`); the recorder, the audio session, the Live Activity, the intents, the Keychain and
// file protection stay in the app (`QuickCapture+App.swift`). No text: the app words the errors (`QuickCapture+Text.swift`).

/// What this device keeps for quick voice notes (docs/quick-capture.md):
/// the vault's capture profile (public recipients and the capture key, never
/// the identity or the vault secret), where the vault is, and whether voice
/// notes are transcribed here.
public struct StoredCaptureProfile: Codable, Equatable, Sendable {
    public var profile: CaptureProfile
    public var vaultName: String
    /// Bookmark of the vault folder (`options: []`, as for recent vaults).
    public var bookmark: Data
    /// Transcribe voice notes on this device when they stop.
    public var transcribe: Bool
    /// This device is not on the vault's newest device list (key-hierarchy design §5.5; review of #87, R1): no
    /// new voice note starts, while a recording in progress, leftovers and the queue are still sealed into
    /// `inbox/` with ledger entries, so the unlisted screen's Save Files covers them. Lifted, keeping the
    /// notebook, once the device is listed again. Absent means not suspended.
    public var suspended: Bool? = nil

    public init(profile: CaptureProfile, vaultName: String, bookmark: Data, transcribe: Bool, suspended: Bool? = nil) {
        self.profile = profile
        self.vaultName = vaultName
        self.bookmark = bookmark
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

/// On disk, next to a recording's audio: enough to save what was recorded if
/// the app is killed before the recording is stopped (the app's `RecordingRecovery`, `CaptureSegments.Leftover`).
public struct RecordingManifest: Codable, Equatable, Sendable {
    /// The manifest's file name in a recording folder.
    static let fileName = "manifest.json"

    var note: UUID
    var recording: UUID
    var started: Date?
    var codec: String
    /// Segment file names in order; the last may be unfinished.
    public var segments: [String]
    /// Segments known to be complete.
    public var finished: Int

    public init(note: UUID, recording: UUID, started: Date?, codec: String, segments: [String], finished: Int) {
        self.note = note
        self.recording = recording
        self.started = started
        self.codec = codec
        self.segments = segments
        self.finished = finished
    }
}

// MARK: - Segments and the seal's rules

/// A quick voice note's recording folder: its segment files, what was left of an interrupted one, and what a
/// seal may do with what it holds (never delete audio that was not sealed: docs/quick-capture.md).
public enum CaptureSegments {
    /// The container of quick voice notes' segment files: ADTS, whose every frame stands alone, so
    /// a recording cut off by a force quit, a crash or a restart keeps its audio up to the last frame.
    /// MPEG-4 (`m4a`, what in-note recordings use) is unreadable until the recorder finishes the file:
    /// a voice note interrupted by a restart was lost whole (TestFlight 1.0.0 (6), iPhone).
    static let segmentExtension = "aac"

    /// The format quick voice notes record in: the recording settings, but AAC for Apple Lossless
    /// (ADTS carries only AAC; `segmentExtension`).
    public static func captureFormat(_ preferred: RecordingFormat) -> RecordingFormat {
        preferred.codec == .alac ? .default : preferred
    }

    /// The segment files of a recording folder, in order: those `listed`
    /// (the session's, or its manifest's), then every other
    /// `segment-NNN.aac` in `folder` by number. A segment begun just before
    /// the app died may be missing from the manifest (its write failed or had
    /// not happened yet); sealing without it and deleting the folder would
    /// lose its audio.
    static func files(listed: [URL], in folder: URL) -> [URL] {
        let names = Set(listed.map(\.lastPathComponent))
        let present = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let extra = present.compactMap { name -> (Int, String)? in
            guard !names.contains(name), let n = number(name) else { return nil }
            return (n, name)
        }.sorted { $0.0 < $1.0 }
        return listed + extra.map { folder.appendingPathComponent($0.1) }
    }

    /// The number of a segment file name (`segment-007.aac` is 7, as `RecordingSession` names them); nil for any
    /// other name.
    public static func number(_ name: String) -> Int? {
        guard name.hasPrefix("segment-"), name.hasSuffix(".aac") else { return nil }
        let digits = name.dropFirst("segment-".count).dropLast(".aac".count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// The size of the file at `url` (0 when it is missing).
    public static func byteCount(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// What a segment file holds (the app reads it with AVFoundation).
    public enum Audio: Equatable, Sendable {
        /// No byte, or a file AVFoundation reads whose audio track is zero
        /// seconds long (a segment stopped before its first frame): nothing to keep.
        case none
        /// Audio of some length (`RecordingAssembly.readable`).
        case audio
        /// Bytes AVFoundation cannot read as audio (unfinished by a crash, or damaged).
        case undecodable
    }

    /// What a seal does with a recording folder's segments.
    enum SealPlan: Equatable, Sendable {
        /// Not a byte recorded, or only finished files of no length (stopped, or the app died, before the
        /// recorder wrote any audio): nothing to keep, the folder goes.
        case nothingRecorded
        /// A complete segment (one of the first `finished`) that does not decode: it is not skipped, since
        /// sealing the others and deleting the folder would lose its audio. The folder waits, as an
        /// unreadable one does.
        case completeSegmentUndecodable(String)
        /// Bytes of which nothing decodes (the app died in the first segment): kept too.
        case noReadableAudio
        /// Merge these segments, in order, and seal them. Only a segment after the first `finished`, the
        /// one being written when the app died, may have been left out as undecodable (docs/attachments.md
        /// §13: a crash loses at most that segment).
        case seal([URL])

        /// Whether the folder may be deleted without sealing (only when nothing was recorded).
        var discardsFolder: Bool { self == .nothingRecorded }
    }

    /// The seal's rule for `held` (every segment file, `files(listed:in:)`, with what it holds), of which the
    /// first `finished` of `listed` (all of them when nil) are complete.
    static func plan(held: [(url: URL, audio: Audio)], listed: [URL], finished: Int?) -> SealPlan {
        if held.allSatisfy({ $0.audio == .none }) { return .nothingRecorded }
        let complete = Set(listed.prefix(max(0, finished ?? listed.count)).map(\.lastPathComponent))
        if let bad = held.first(where: { $0.audio == .undecodable && complete.contains($0.url.lastPathComponent) }) {
            return .completeSegmentUndecodable(bad.url.lastPathComponent)
        }
        let audio = held.filter { $0.audio == .audio }.map(\.url)
        return audio.isEmpty ? .noReadableAudio : .seal(audio)
    }

    /// What a recording folder left in `root` holds, from its manifest when
    /// it can be read, else from its files: a session's folder is named by
    /// its recording id, and its segments by number (`files(listed:in:)`). Without
    /// a manifest every segment but the last counts as complete.
    struct Leftover: Equatable, Sendable {
        var id: UUID?
        var segments: [URL]
        var finished: Int?
        var started: Date?

        static let maxManifestBytes = 1 << 20

        /// Nil when the manifest is there but cannot be read now.
        init?(folder: URL) {
            let fm = FileManager.default
            let url = folder.appendingPathComponent(RecordingManifest.fileName)
            var manifest: RecordingManifest?
            let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
            if let size, size <= Self.maxManifestBytes {
                guard let data = try? BoundedRead.contents(of: url, maxBytes: Self.maxManifestBytes) else { return nil }
                manifest = try? JSONDecoder().decode(RecordingManifest.self, from: data)
            }
            // Only names a session gives its segments: never a path out of the folder.
            let listed = (manifest?.segments ?? []).filter { CaptureSegments.number($0) != nil }
                .map { folder.appendingPathComponent($0) }
            segments = CaptureSegments.files(listed: listed, in: folder)
            if let manifest {
                id = manifest.recording
                finished = min(max(0, manifest.finished), listed.count)
                started = manifest.started
            } else {
                id = UUID(uuidString: folder.lastPathComponent)
                finished = max(0, segments.count - 1)
                started = segments.compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.creationDate] as? Date }.min()
            }
        }
    }
}

// MARK: - Delivery

/// Where a sealed voice note goes: the profile's vault's `inbox/` (its in-app copy when the store holds it, else
/// the folder its bookmark names), or this device's queue when that folder cannot be reached, is not the profile's
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
    /// Resolves the profile's bookmark and holds its scope (the app's security-scoped bookmarks).
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
        let queue = queueFolder(stored.profile.vaultId)
        // The epoch it was sealed under goes with it, written BEFORE the file (review nit): a crash between the two
        // leaves a sidecar without a file (ignored), never a file without its epoch. The flush records that epoch,
        // never a newer profile's (M4).
        if let epoch = sealed.epoch, let id = sealed.epochId {
            try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
            try Data("\(epoch) \(id.map { String(format: "%02x", $0) }.joined())\n".utf8)
                .write(to: Self.epochSidecar(queue.appendingPathComponent(sealed.name)), options: .atomic)
        }
        try CaptureWriter.store(sealed, in: queue)
        return .queued
    }

    /// `<queued file>.epoch`: "<epoch> <epoch id hex>", the epoch of the profile that sealed it.
    static func epochSidecar(_ file: URL) -> URL { file.appendingPathExtension("epoch") }

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

    func queueFolder(_ vault: UUID) -> URL {
        queueRoot.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true)
    }

    /// The folder of the profile's vault: its in-app copy when the store holds it (found by id, so a moved
    /// store or a stale bookmark does not matter), else the folder its bookmark names.
    func vaultFolder(_ stored: StoredCaptureProfile) -> URL? {
        vaultStore?.entry(id: stored.profile.vaultId)?.url ?? (try? bookmarks.resolve(stored.bookmark))?.url
    }

    /// Moves queued captures of `vaultId` into the vault at `vaultURL`
    /// (sealed already: plain file moves), each inside a write `files` coordinates (iCloud Drive). Returns how
    /// many moved. Nothing moves into a read-only vault (format.md §7.3): they stay queued.
    ///
    /// - Parameter profile: a profile of this vault, to record them in its ledger (design §5.4) under the epoch
    ///   each was sealed with (its sidecar; a file queued before sidecars existed takes the profile's); with a
    ///   ledger and no such profile they stay queued, never placed unrecorded.
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
                if ledger != nil {
                    guard let profile, profile.vaultId == vaultId else { continue }
                    try record(sealed, profile)
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
