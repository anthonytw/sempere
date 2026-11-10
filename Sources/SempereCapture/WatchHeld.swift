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
}

public enum WatchHeldError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 200 files or 500 MB are held already: the file is refused, unacknowledged, and the watch keeps it.
    case full
    case notFound(String)
    case ambiguous(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .full: return "too many Watch notes are held (200 files or 500 MB): add or delete some first"
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
    static let sidecarSuffix = ".held.json"

    public let root: URL
    private let maxFiles: Int
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    /// - Parameters:
    ///   - maxFiles: the most files held (tests lower it).
    ///   - maxBytes: the most bytes held.
    public init(root: URL, maxFiles: Int = WatchHeldStore.maxFiles, maxBytes: Int = WatchHeldStore.maxTotalBytes,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
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

    private func scan() -> [HeldCapture] {
        let fm = FileManager.default
        var out: [HeldCapture] = []
        for dir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard UUID(uuidString: dir) != nil else { continue }
            let url = root.appendingPathComponent(dir, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where name.hasSuffix(Self.sidecarSuffix) {
                guard let data = try? BoundedRead.contents(of: url.appendingPathComponent(name), maxBytes: 4096),
                      let held = try? decoder().decode(HeldCapture.self, from: data) else { continue }
                let file = url.appendingPathComponent(CaptureFile.name(held.id, .capture))
                guard fm.fileExists(atPath: file.path) else { continue }
                out.append(held)
            }
        }
        return out.sorted { ($0.receivedAt, $0.id.uuidString) < ($1.receivedAt, $1.id.uuidString) }
    }

    public var count: Int { list().count }

    /// Keeps `sealed` (a file the intake checked), unless it is held already. Throws `.full` past the caps.
    public func hold(_ sealed: SealedCapture, vault: UUID, reason: WatchHeldReason) throws {
        try lock.withLock {
            guard let parsed = CaptureFile.parse(name: sealed.name), parsed.kind == .capture,
                  let epoch = sealed.epoch, let epochId = sealed.epochId else {
                throw WatchHeldError.unreadable("not a watch capture")
            }
            let existing = scan()
            if existing.contains(where: { $0.id == parsed.id && $0.vault == vault }) { return }
            guard existing.count < maxFiles,
                  existing.reduce(0, { $0 + $1.bytes }) + sealed.data.count <= maxBytes else { throw WatchHeldError.full }
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
