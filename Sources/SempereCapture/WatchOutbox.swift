import Foundation
import Sempere

// The watch's queue of sealed captures (docs/design/1.1-watch.md §3.3, §3.6): `<id>.capture.age` files and an index
// (`outbox.json`). Only ciphertext and ids. The rules:
//  - No ack, no delete, ever: a transfer error keeps the file, and a file with no ack for 24 hours is sent again.
//  - A recording that has been sealed is never refused or dropped for lack of room: the caps only keep a NEW recording from
//    starting (`canStartRecording`); `add` never throws for size.
//  - A damaged index never loses a file: it is set aside and rebuilt from the per-file metadata sidecars.

public enum WatchOutboxError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The outbox holds as many files or bytes as it may: "Open Sempere on your iPhone to send saved notes".
    case full
    /// The device has less free space than a recording needs.
    case lowStorage
    case io(String)

    public var description: String {
        switch self {
        case .full: return "the outbox is full: open Sempere on your iPhone to send saved notes"
        case .lowStorage: return "not enough free space on the watch to record"
        case .io(let why): return "outbox: \(why)"
        }
    }
}

/// The sealed captures waiting to reach the iPhone.
public final class WatchOutbox: @unchecked Sendable {
    public enum State: String, Codable, Sendable {
        /// Waiting for a transfer (new, or the last one failed).
        case sealed
        /// Handed to WatchConnectivity; waiting for the phone's ack.
        case transferring
        /// The phone has it: the file is gone, the entry stays a while so a repeated ack is a no-op.
        case acked
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var meta: WatchTransferMeta
        public var state: State
        /// Transfers started so far.
        public var attempts: Int
        public var created: Date
        /// When the last transfer started.
        public var lastSent: Date?
        /// A failed transfer is not retried before this (backoff); every launch retries regardless.
        public var nextAttempt: Date?
        public var ackedAt: Date?

        public var id: UUID { meta.id }
    }

    public struct Limits: Equatable, Sendable {
        public var maxFiles = 200
        public var maxBytes = 500 << 20
        /// Less free space than this and a new recording is refused.
        public var minFreeBytes: Int64 = 1 << 30
        /// With no ack after this long a transfer is started again.
        public var resendAfter: TimeInterval = 24 * 3600
        /// How long an acked entry is remembered.
        public var keepAcked: TimeInterval = 30 * 24 * 3600
        public init() {}
    }

    public static let indexName = "outbox.json"
    public static let sidecarExtension = "meta.json"
    static let maxIndexBytes = 16 << 20

    public let directory: URL
    public let limits: Limits
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    /// The index was unreadable and was rebuilt from the sidecars (the old one is kept as `outbox.json.damaged-<time>`).
    public private(set) var recoveredIndex = false

    public init(directory: URL, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.directory = directory
        self.limits = limits
        self.now = now
        try FileIO.createDirectory(directory)
        try load()
    }

    private var indexURL: URL { directory.appendingPathComponent(Self.indexName) }

    private static func coders() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    private func load() throws {
        let fm = FileManager.default
        let (_, decoder) = Self.coders()
        var loaded: [Entry]?
        if fm.fileExists(atPath: indexURL.path) {
            if let data = try? BoundedRead.contents(of: indexURL, maxBytes: Self.maxIndexBytes),
               let list = try? decoder.decode([Entry].self, from: data) {
                loaded = list
            } else {
                // Damaged: keep it, never delete a sealed file because of it.
                let stamp = Int64(now().timeIntervalSince1970)
                try? fm.moveItem(at: indexURL, to: directory.appendingPathComponent("\(Self.indexName).damaged-\(stamp)"))
                recoveredIndex = true
            }
        }
        var map: [UUID: Entry] = [:]
        for e in loaded ?? [] { map[e.id] = e }
        // Any capture file the index does not know (a crash between the file and the index, or a damaged index) comes back
        // from its sidecar as unsent.
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            guard let parsed = CaptureFile.parse(name: name), parsed.kind == .capture, map[parsed.id] == nil else { continue }
            let sidecar = directory.appendingPathComponent("\(parsed.id.uuidString.lowercased()).\(Self.sidecarExtension)")
            guard let data = try? BoundedRead.contents(of: sidecar, maxBytes: 4096),
                  let meta = try? JSONDecoder().decode(WatchTransferMeta.self, from: data), meta.id == parsed.id,
                  meta.name == name else { continue }
            map[parsed.id] = Entry(meta: meta, state: .sealed, attempts: 0, created: now(), lastSent: nil, nextAttempt: nil,
                                   ackedAt: nil)
        }
        // Forget acked entries after a while, and entries whose file is gone without an ack never happen by this class: an
        // unacked entry whose file vanished is kept as it is (it cannot be sent; `unsent` shows it).
        let cutoff = now().addingTimeInterval(-limits.keepAcked)
        map = map.filter { _, e in e.state != .acked || (e.ackedAt ?? .distantPast) > cutoff }
        lock.withLock { entries = map }
        if loaded == nil || recoveredIndex { try save() }
    }

    private func save() throws {
        let list = lock.withLock { entries.values.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) } }
        let (encoder, _) = Self.coders()
        do { try FileIO.writePrivate(try encoder.encode(list), to: indexURL) } catch {
            throw WatchOutboxError.io("\(error)")
        }
    }

    // MARK: Reading

    /// Every entry, oldest first.
    public var all: [Entry] {
        lock.withLock { entries.values.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) } }
    }

    public func entry(_ id: UUID) -> Entry? { lock.withLock { entries[id] } }

    /// The notes the phone has not acknowledged.
    public var unsent: [Entry] { all.filter { $0.state != .acked } }
    public var unsentCount: Int { lock.withLock { entries.values.filter { $0.state != .acked }.count } }

    /// Bytes of the sealed files still held.
    public var heldBytes: Int {
        // Summed as Int64: the watch's `Int` may be 32 bits.
        Int(clamping: lock.withLock { entries.values.filter { $0.state != .acked }.reduce(Int64(0)) { $0 + Int64($1.meta.size) } })
    }

    public func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(CaptureFile.name(id, .capture)) }

    private func sidecarURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).\(Self.sidecarExtension)")
    }

    /// Whether a new recording may start: below the caps, with room on the device (`freeBytes`, nil when unknown).
    public func canStartRecording(freeBytes: Int64?) throws {
        if unsentCount >= limits.maxFiles || heldBytes >= limits.maxBytes { throw WatchOutboxError.full }
        if let freeBytes, freeBytes < limits.minFreeBytes { throw WatchOutboxError.lowStorage }
    }

    // MARK: Adding

    /// Puts a sealed capture in the outbox (file first, then its sidecar, then the index: a crash in between leaves a file
    /// the next launch finds). Adding an id that is there is a no-op that returns its metadata. Never refuses for size.
    @discardableResult
    public func add(_ sealed: SealedCapture, vault: UUID) throws -> WatchTransferMeta {
        let meta = try WatchTransferMeta(sealed: sealed, vault: vault)
        if let have = entry(meta.id), have.state != .acked { return have.meta }
        do {
            try CaptureWriter.store(sealed, in: directory)
            let (encoder, _) = Self.coders()
            try FileIO.writePrivate(try encoder.encode(meta), to: sidecarURL(meta.id))
        } catch { throw WatchOutboxError.io("\(error)") }
        lock.withLock {
            entries[meta.id] = Entry(meta: meta, state: .sealed, attempts: 0, created: now(), lastSent: nil, nextAttempt: nil,
                                     ackedAt: nil)
        }
        try save()
        return meta
    }

    // MARK: Transfers

    /// The backoff after `attempts` transfers: 30 s, doubling, up to an hour.
    static func backoff(attempts: Int) -> TimeInterval {
        min(3600, 30 * pow(2, Double(max(0, min(attempts - 1, 12)))))
    }

    /// The entries to hand to WatchConnectivity now: sealed ones past their backoff (all of them with `launch`: every
    /// launch retries), and transferring ones with no ack for `resendAfter`. Only entries whose file is there.
    public func due(launch: Bool = false) -> [Entry] {
        let t = now()
        return all.filter { e in
            guard FileManager.default.fileExists(atPath: fileURL(e.id).path) else { return false }
            switch e.state {
            case .sealed: return launch || (e.nextAttempt ?? .distantPast) <= t
            case .transferring: return (e.lastSent ?? .distantPast).addingTimeInterval(limits.resendAfter) <= t
            case .acked: return false
            }
        }
    }

    /// `transferFile` was called for `id`.
    public func markTransferring(_ id: UUID) throws {
        let changed: Bool = lock.withLock {
            guard var e = entries[id], e.state != .acked else { return false }
            e.state = .transferring
            e.attempts += 1
            e.lastSent = now()
            e.nextAttempt = nil
            entries[id] = e
            return true
        }
        if changed { try save() }
    }

    /// The transfer failed (`didFinish` with an error): the file stays, to be sent again after a backoff.
    public func transferFailed(_ id: UUID) throws {
        let changed: Bool = lock.withLock {
            guard var e = entries[id], e.state != .acked else { return false }
            e.state = .sealed
            e.nextAttempt = now().addingTimeInterval(Self.backoff(attempts: e.attempts))
            entries[id] = e
            return true
        }
        if changed { try save() }
    }

    // MARK: Acks

    /// The phone has these (`acked`, or `have` at its activation): the files go. An id the outbox does not know, or already
    /// acked, does nothing. Returns the ids whose files were deleted.
    @discardableResult
    public func acknowledge(_ ids: [UUID]) throws -> [UUID] {
        var removed: [UUID] = []
        for id in ids {
            let known: Bool = lock.withLock { entries[id].map { $0.state != .acked } ?? false }
            guard known else { continue }
            try? FileManager.default.removeItem(at: fileURL(id))
            try? FileManager.default.removeItem(at: sidecarURL(id))
            lock.withLock {
                entries[id]?.state = .acked
                entries[id]?.ackedAt = now()
                entries[id]?.nextAttempt = nil
            }
            removed.append(id)
        }
        if !removed.isEmpty { try save() }
        return removed
    }

    public func acknowledge(_ ack: WatchAck) throws -> [UUID] { try acknowledge(ack.ids) }

    /// The sealed file of `id`, read back (to hand to the CLI's `receive`, or to check).
    public func sealedData(_ id: UUID) throws -> Data {
        try BoundedRead.contents(of: fileURL(id), maxBytes: CaptureFile.maxBytes)
    }
}
