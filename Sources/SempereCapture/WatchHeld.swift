import Foundation
import Sempere

// Watch files the phone did not admit (docs/design/1.1-watch.md §3.4 "Admission"): kept on this device only, never in a
// vault folder, never synced, never in the write ledger, until the user adds them to the inbox or deletes them.

/// Why a watch file was held.
public enum WatchHeldReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// "Use on Apple Watch" was off when it arrived.
    case linkOff
    /// Sealed under an earlier epoch than the one this device holds, and this device kept that epoch's key.
    case oldEpoch
    /// The vault's folder is already on a newer epoch than this device holds a profile for.
    case newerEpoch
    /// This device's profile is suspended (it was removed from the vault's device list).
    case suspended
    /// Sealed under an epoch this device never held. Only Delete is offered.
    case unknownEpoch
    /// For a vault this device does not hold. Only Delete is offered.
    case unknownVault

    /// Whether Add to inbox is offered: the file can be recorded and caught up.
    public var canAdd: Bool { self != .unknownEpoch && self != .unknownVault }

    /// Whether the note needs the user's check before it is added: it arrived after "Use on Apple Watch" went off, or
    /// under an earlier key. After a lost watch's steps (the toggle off, then a new key) that is exactly what the lost watch
    /// sends, so such a note is offered for Delete first and added only one at a time, after a warning; `held add --all`
    /// skips it.
    public var needsCheck: Bool { self == .linkOff || self == .oldEpoch }
}

/// One held file.
public struct HeldCapture: Codable, Equatable, Sendable {
    public var id: UUID
    public var vault: UUID
    public var epoch: Int
    /// 64 lowercase hex digits.
    public var epochId: String
    public var receivedAt: Date
    public var reason: WatchHeldReason
    public var bytes: Int

    public var canAdd: Bool { reason.canAdd }
    /// `WatchHeldReason.needsCheck`.
    public var needsCheck: Bool { reason.needsCheck }
}

public enum WatchHeldError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 200 files or 500 MB are held already: the file is refused, unacknowledged, and the watch keeps it.
    case full
    /// 20 files or 50 MB of notes that can only be deleted (`WatchHeldReason.canAdd` false) are held already: refused like
    /// `.full`, so a watch sending notes for a vault this phone does not hold cannot use up the room for notes the user can add.
    case fullUnplaceable
    case notFound(String)
    case ambiguous(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .full: return "too many Watch notes are held (200 files or 500 MB): add or delete some first"
        case .fullUnplaceable:
            return "too many Watch notes that can only be deleted are held (20 files or 50 MB): delete some first"
        case .notFound(let s): return "no held Watch note matches \(s)"
        case .ambiguous(let s): return "\(s) matches more than one held Watch note"
        case .unreadable(let s): return "the held note cannot be read: \(s)"
        }
    }
}

/// `Application Support/Sempere/WatchHeld/<vault>/<id>.capture.age`, each with `<id>.capture.age.held.json` beside it.
public final class WatchHeldStore: @unchecked Sendable {
    public static let maxFiles = 200
    public static let maxTotalBytes = 500 << 20
    /// The sub-limit for notes that can only be deleted (`unknownVault`, `unknownEpoch`): inside the general caps, not extra room.
    public static let maxUnplaceableFiles = 20
    public static let maxUnplaceableBytes = 50 << 20
    /// A file without a valid sidecar is removed once it is older than this: a younger one may be a `hold` in progress in
    /// another process (file first, sidecar second; the store's lock is in-process only).
    public static let orphanAge: TimeInterval = 24 * 3600
    static let sidecarSuffix = ".held.json"

    public let root: URL
    private let maxFiles: Int
    private let maxBytes: Int
    private let maxUnplaceableFiles: Int
    private let maxUnplaceableBytes: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var orphansRemoved = 0
    /// Serializes "Add to inbox" (`take`), so two adds of one note cannot both place it.
    private let takeLock = NSLock()

    /// Whether a store that holds `held` refuses another file: the rule `hold` applies (`adding` is the new file's size; with
    /// none, the least a file weighs).
    /// Whether a store that holds `held` refuses another note that can only be deleted: the sub-limit `hold` applies.
    public static func isFullOfUnplaceable(_ held: [HeldCapture], adding: Int = 1, maxFiles: Int = maxUnplaceableFiles,
                                           maxBytes: Int = maxUnplaceableBytes) -> Bool {
        let u = held.filter { !$0.canAdd }
        return u.count >= maxFiles || u.reduce(0, { $0 + $1.bytes }) + adding > maxBytes
    }

    public static func isFull(_ held: [HeldCapture], adding: Int = 1, maxFiles: Int = maxFiles,
                              maxBytes: Int = maxTotalBytes) -> Bool {
        held.count >= maxFiles || held.reduce(0, { $0 + $1.bytes }) + adding > maxBytes
    }

    /// Whether the next file would be refused: 200 files or 500 MB (or this store's lower caps) are held.
    public var isFull: Bool { Self.isFull(list(), maxFiles: maxFiles, maxBytes: maxBytes) }

    /// - Parameters:
    ///   - maxFiles: the most files held (tests lower it).
    ///   - maxBytes: the most bytes held.
    ///   - maxUnplaceableFiles: the most notes that can only be deleted.
    ///   - maxUnplaceableBytes: their bytes.
    public init(root: URL, maxFiles: Int = WatchHeldStore.maxFiles, maxBytes: Int = WatchHeldStore.maxTotalBytes,
                maxUnplaceableFiles: Int = WatchHeldStore.maxUnplaceableFiles,
                maxUnplaceableBytes: Int = WatchHeldStore.maxUnplaceableBytes,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
        self.maxUnplaceableFiles = maxUnplaceableFiles
        self.maxUnplaceableBytes = maxUnplaceableBytes
        self.now = now
    }

    private func folder(_ vault: UUID) -> URL { root.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true) }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Every held file, oldest first.
    public func list() -> [HeldCapture] {
        lock.withLock { scan() }
    }

    /// Lists the held files, and removes what has no partner (a file without a valid sidecar, a sidecar without its file)
    /// once it is older than `orphanAge`.
    private func scan() -> [HeldCapture] {
        let fm = FileManager.default
        var out: [HeldCapture] = []
        let cutoff = now().addingTimeInterval(-Self.orphanAge)
        func old(_ url: URL) -> Bool {
            guard let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
            return m < cutoff
        }
        for dir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard UUID(uuidString: dir) != nil else { continue }
            let url = root.appendingPathComponent(dir, isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            var paired = Set<String>()
            for name in names where name.hasSuffix(Self.sidecarSuffix) {
                let sidecar = url.appendingPathComponent(name)
                guard let data = try? BoundedRead.contents(of: sidecar, maxBytes: 4096),
                      let held = try? decoder().decode(HeldCapture.self, from: data) else { continue }
                let fileName = CaptureFile.name(held.id, .capture)
                let file = url.appendingPathComponent(fileName)
                guard fm.fileExists(atPath: file.path) else {
                    if old(sidecar), (try? fm.removeItem(at: sidecar)) != nil { orphansRemoved += 1 }
                    continue
                }
                paired.insert(fileName)
                paired.insert(fileName + Self.sidecarSuffix)
                out.append(held)
            }
            for name in names where !paired.contains(name) {
                guard name.hasSuffix(Self.sidecarSuffix) || CaptureFile.parse(name: name)?.kind == .capture else { continue }
                let target = url.appendingPathComponent(name)
                if old(target), (try? fm.removeItem(at: target)) != nil { orphansRemoved += 1 }
            }
        }
        return out.sorted { ($0.receivedAt, $0.id.uuidString) < ($1.receivedAt, $1.id.uuidString) }
    }

    public var count: Int { list().count }

    /// How many files (and sidecars) the sweeps of `list` and `hold` removed since the last call; the call resets it.
    public func takeOrphansRemoved() -> Int {
        lock.withLock {
            defer { orphansRemoved = 0 }
            return orphansRemoved
        }
    }

    /// The held notes per reason, after a sweep.
    public func countsByReason() -> [WatchHeldReason: Int] {
        Dictionary(list().map { ($0.reason, 1) }, uniquingKeysWith: +)
    }

    /// Keeps `sealed` (a file the intake checked), unless it is held already. Throws `.full` past the caps.
    public func hold(_ sealed: SealedCapture, vault: UUID, reason: WatchHeldReason) throws {
        try lock.withLock {
            guard let parsed = CaptureFile.parse(name: sealed.name), parsed.kind == .capture,
                  let epoch = sealed.epoch, let epochId = sealed.epochId else {
                throw WatchHeldError.unreadable("not a watch capture")
            }
            let existing = scan()
            if existing.contains(where: { $0.id == parsed.id && $0.vault == vault }) { return }
            guard !Self.isFull(existing, adding: sealed.data.count, maxFiles: maxFiles, maxBytes: maxBytes) else {
                throw WatchHeldError.full
            }
            guard reason.canAdd || !Self.isFullOfUnplaceable(existing, adding: sealed.data.count, maxFiles: maxUnplaceableFiles,
                                                                maxBytes: maxUnplaceableBytes) else {
                throw WatchHeldError.fullUnplaceable
            }
            let held = HeldCapture(id: parsed.id, vault: vault, epoch: epoch, epochId: Hex.encode(epochId), receivedAt: now(),
                                   reason: reason, bytes: sealed.data.count)
            let dir = folder(vault)
            try FileIO.createDirectory(dir)
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            e.dateEncodingStrategy = .iso8601
            // The file first: a sidecar without a file is ignored, a file without a sidecar is never listed (and is removed
            // below if the sidecar cannot be written).
            try CaptureWriter.store(SealedCapture(name: sealed.name, data: sealed.data), in: dir)
            do {
                try FileIO.writePrivate(try e.encode(held), to: dir.appendingPathComponent(sealed.name + Self.sidecarSuffix))
            } catch {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(sealed.name))
                throw error
            }
        }
    }

    /// The held file `selector` names: a full id or a unique prefix of at least 4 characters.
    public func find(_ selector: String) throws -> HeldCapture {
        let s = selector.lowercased()
        let all = list()
        let matches = all.filter { $0.id.uuidString.lowercased() == s }
        let found = matches.isEmpty && s.count >= 4 ? all.filter { $0.id.uuidString.lowercased().hasPrefix(s) } : matches
        guard let first = found.first else { throw WatchHeldError.notFound(selector) }
        guard found.count == 1 else { throw WatchHeldError.ambiguous(selector) }
        return first
    }

    /// The sealed file, with the epoch it was sealed under.
    public func load(_ held: HeldCapture) throws -> SealedCapture {
        let file = folder(held.vault).appendingPathComponent(CaptureFile.name(held.id, .capture))
        guard let id = Hex.decode(held.epochId) else { throw WatchHeldError.unreadable("bad epoch id") }
        do {
            let data = try BoundedRead.contents(of: file, maxBytes: CaptureFile.maxSealedBytes(.capture))
            return SealedCapture(name: file.lastPathComponent, data: data, epoch: held.epoch, epochId: id)
        } catch { throw WatchHeldError.unreadable("\(error)") }
    }

    /// Runs `body` on the held file, then removes it: one at a time, so a second add of the same note (a double tap) finds it
    /// gone. Returns nil when it is no longer held; a throwing `body` leaves the file held.
    public func take<T>(_ held: HeldCapture, _ body: (SealedCapture) throws -> T) throws -> T? {
        try takeLock.withLock {
            guard list().contains(where: { $0.id == held.id && $0.vault == held.vault }) else { return nil }
            let result = try body(try load(held))
            delete(held)
            return result
        }
    }

    /// Removes the file and its sidecar.
    public func delete(_ held: HeldCapture) {
        lock.withLock {
            let dir = folder(held.vault)
            let name = CaptureFile.name(held.id, .capture)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name + Self.sidecarSuffix))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
