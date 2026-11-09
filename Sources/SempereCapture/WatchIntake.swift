import Foundation
import Sempere

// The phone side of the hand-off (docs/design/1.1-watch.md §3.6, steps 1 to 4), once, for the iPhone and the CLI:
//  1. the metadata is checked against the file (the file crossed a daemon: nothing in it is trusted);
//  2. an id already received, or already in the inbox, is not placed again, but is acknowledged;
//  3. otherwise the file is delivered by `meta.vault`, never into the current vault's inbox unless that is its vault;
//  4. the id joins the received set and is acknowledged.
// The platform part is `WatchDelivery`: the app's adapter over `CaptureDelivery`, the CLI's over the vault's ledger and
// `CaptureWriter.store`. The phone never decrypts anything here.

/// Why a transferred file was refused (never placed, never acknowledged: the watch keeps it, and it is reported).
public enum WatchIntakeProblem: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedVersion(Int)
    /// `meta.name` is not `CaptureFile.name(meta.id, .capture)`.
    case nameMismatch
    /// The file is larger than a capture can be, or its size is not `meta.size`.
    case sizeMismatch
    case tooLarge
    case hashMismatch
    /// The epoch fields are not a non-negative epoch and 32 bytes of hex.
    case badEpoch
    case unreadable(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): return "transfer metadata version \(v) is not supported"
        case .nameMismatch: return "the file name does not match the capture id"
        case .sizeMismatch: return "the file's size does not match its metadata"
        case .tooLarge: return "the file is larger than a capture can be"
        case .hashMismatch: return "the file's SHA-256 does not match its metadata"
        case .badEpoch: return "the metadata's epoch is not valid"
        case .unreadable(let why): return "the file cannot be read: \(why)"
        }
    }
}

/// Where a received capture went.
public enum WatchPlacement: Equatable, Sendable {
    /// Into the current vault's inbox (ledger first).
    case vault
    /// The current vault's inbox was not reachable: into its queue, recorded when it is placed.
    case queued
    /// Another vault the device holds: into that vault's inbox, recorded in that vault's ledger.
    case otherVault
    /// A vault the device does not hold (or cannot write now): into its queue, unrecorded, until it is opened.
    case otherVaultQueued
}

/// What `WatchIntake.receive` did with one file.
public struct WatchIntakeResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case placed(WatchPlacement)
        /// Already received or already in the inbox: not placed again, but acknowledged.
        case duplicate
        case refused(WatchIntakeProblem)
    }

    public var id: UUID
    public var outcome: Outcome

    /// Whether the watch may drop its copy: the file is in the vault or its queue.
    public var acknowledged: Bool {
        switch outcome {
        case .placed, .duplicate: return true
        case .refused: return false
        }
    }
}

/// The platform half of an intake. Nothing here validates: `WatchIntake` has.
public protocol WatchDelivery: Sendable {
    /// The vault the device's stored capture profile serves; nil without one.
    var currentVault: UUID? { get }
    /// Whether capture `id` is in vault `vault`'s inbox already (which the device can read).
    func inboxHolds(id: UUID, vault: UUID) -> Bool
    /// The stored profile's vault: `CaptureDelivery.deliver`. Records in the ledger first, then writes the inbox, or the
    /// queue when its folder cannot be reached.
    func deliverToCurrent(_ sealed: SealedCapture) throws -> WatchPlacement
    /// Whether the device holds vault `vault` (its in-app copy, by id).
    func holds(vault: UUID) -> Bool
    /// Records `sealed` in `vault`'s ledger under its own epoch, then places it in that vault's inbox. False (nothing
    /// recorded or placed) when that vault cannot take it now (read-only, unreachable).
    func recordAndPlace(_ sealed: SealedCapture, in vault: UUID) throws -> Bool
    /// Puts `sealed` in `vault`'s queue with its epoch beside it, unrecorded (it is recorded when it is placed: a ledger
    /// entry whose file is not at its path is dropped after an hour, so recording at queue time would lose the catch-up).
    func queue(_ sealed: SealedCapture, for vault: UUID) throws
}

/// The ids already received (`Application Support/Sempere/WatchReceived.json`): 180 days, bounded in number. Losing it only
/// costs repeated checks: a duplicate never makes a second note (names are `<id>…`, `CaptureWriter.store` never
/// overwrites, and adoption derives the same note ids).
public final class WatchReceivedSet: @unchecked Sendable {
    public static let keepFor: TimeInterval = 180 * 24 * 3600
    public static let maxCount = 20_000
    static let maxFileBytes = 4 << 20

    private struct Row: Codable { var id: String; var at: Date }

    private let url: URL?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var rows: [UUID: Date] = [:]

    /// - Parameter url: the file; nil keeps the set in memory (tests).
    public init(url: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
        if let url, let data = try? BoundedRead.contents(of: url, maxBytes: Self.maxFileBytes) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            for row in (try? d.decode([Row].self, from: data)) ?? [] {
                if let id = UUID(uuidString: row.id) { rows[id] = row.at }
            }
        }
        prune()
    }

    public func contains(_ id: UUID) -> Bool { lock.withLock { rows[id] != nil } }
    public var count: Int { lock.withLock { rows.count } }

    /// The newest ids, for `WatchAck.have`.
    public func newest(_ limit: Int = WatchAck.maxIDs) -> [UUID] {
        lock.withLock { rows.sorted { ($0.value, $0.key.uuidString) > ($1.value, $1.key.uuidString) }.prefix(limit).map(\.key) }
    }

    /// Adds `id` (now) and writes the set.
    public func insert(_ id: UUID) throws {
        lock.withLock { rows[id] = now() }
        prune()
        try save()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.keepFor)
        lock.withLock {
            rows = rows.filter { $0.value > cutoff }
            if rows.count > Self.maxCount {
                let keep = rows.sorted { ($0.value, $0.key.uuidString) > ($1.value, $1.key.uuidString) }.prefix(Self.maxCount)
                rows = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
        }
    }

    private func save() throws {
        guard let url else { return }
        let list = lock.withLock { rows.map { Row(id: $0.key.uuidString.lowercased(), at: $0.value) }.sorted { $0.id < $1.id } }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try FileIO.createDirectory(url.deletingLastPathComponent())
        try FileIO.writePrivate(try e.encode(list), to: url)
    }
}

/// The phone side's checks and routing.
public struct WatchIntake: Sendable {
    public let received: WatchReceivedSet
    public let delivery: any WatchDelivery

    public init(received: WatchReceivedSet, delivery: any WatchDelivery) {
        self.received = received
        self.delivery = delivery
    }

    /// Step 1: `meta` against the file's bytes. Returns the sealed capture, as `meta` describes it.
    static func check(file: URL, meta: WatchTransferMeta) throws -> SealedCapture {
        guard meta.version == WatchTransferMeta.currentVersion else { throw WatchIntakeProblem.unsupportedVersion(meta.version) }
        guard meta.name == CaptureFile.name(meta.id, .capture) else { throw WatchIntakeProblem.nameMismatch }
        guard meta.epoch >= 0, let epochId = meta.epochIdBytes else { throw WatchIntakeProblem.badEpoch }
        let limit = CaptureFile.maxSealedBytes(.capture)
        guard meta.size > 0, meta.size <= limit else { throw WatchIntakeProblem.tooLarge }
        let data: Data
        do { data = try BoundedRead.contents(of: file, maxBytes: limit) } catch {
            throw WatchIntakeProblem.unreadable("\(error)")
        }
        guard data.count == meta.size else { throw WatchIntakeProblem.sizeMismatch }
        guard FileDigest.sha256(data) == meta.sha256 else { throw WatchIntakeProblem.hashMismatch }
        return SealedCapture(name: meta.name, data: data, epoch: meta.epoch, epochId: epochId)
    }

    /// Takes one transferred file (a copy the caller owns: WatchConnectivity's file is only valid during its callback).
    /// A failure after the checks (the vault cannot be written, the ledger cannot record) throws: nothing is
    /// acknowledged, and the watch sends the file again.
    public func receive(file: URL, meta: WatchTransferMeta) throws -> WatchIntakeResult {
        let sealed: SealedCapture
        do { sealed = try Self.check(file: file, meta: meta) } catch let problem as WatchIntakeProblem {
            return WatchIntakeResult(id: meta.id, outcome: .refused(problem))
        }
        // Step 2.
        if received.contains(meta.id) || delivery.inboxHolds(id: meta.id, vault: meta.vault) {
            try? received.insert(meta.id)
            return WatchIntakeResult(id: meta.id, outcome: .duplicate)
        }
        // Step 3: by the capture's own vault.
        let placement: WatchPlacement
        if delivery.currentVault == meta.vault {
            placement = try delivery.deliverToCurrent(sealed)
        } else if delivery.holds(vault: meta.vault), try delivery.recordAndPlace(sealed, in: meta.vault) {
            placement = .otherVault
        } else {
            try delivery.queue(sealed, for: meta.vault)
            placement = .otherVaultQueued
        }
        // Step 4: the id is remembered even if the set cannot be written (the file is placed; a repeat is a duplicate).
        try? received.insert(meta.id)
        return WatchIntakeResult(id: meta.id, outcome: .placed(placement))
    }

    /// What the phone sends at the watch's activation: the ids it holds.
    public func have() -> WatchAck { WatchAck(have: received.newest()) }
}

/// Appends a ledger entry for a capture sealed under its own epoch (`CaptureWriter.record` needs a profile only as a
/// fallback epoch, and a watch's capture always carries one).
public enum WatchLedger {
    public static func record(_ sealed: SealedCapture, in ledger: (any WriteLedgerStore)?) throws {
        guard let ledger else { return }
        guard let epoch = sealed.epoch, let epochId = sealed.epochId else { throw WatchTransferError.missingEpoch }
        try ledger.append([LedgerEntry(path: "\(CaptureFile.folderName)/\(sealed.name)", sha256: FileDigest.sha256(sealed.data),
                                       epoch: epoch, epochId: epochId)])
    }
}
