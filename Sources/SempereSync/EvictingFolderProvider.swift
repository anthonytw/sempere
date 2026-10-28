import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - A provider simulated on any file system (docs/ci.md "Transports")
//
// `EvictingFolderProvider` makes a plain folder behave like one iCloud Drive
// holds, so the folder transport's provider paths and the engine's arrival
// rules are tested on Linux (the design's `EvictingFolderRemote`: a
// `FolderRemote` over this provider; a port of the app tests' `FakeCloud`):
//
// - `evict(_:as: .dataless)`: the file keeps its name and size, its bytes go
//   to the provider's side store (`cloud`) and what is left on disk is zeros
//   (a reader that ignored the availability would get wrong bytes, and the
//   checks would say so); `.standIn`: the file is replaced by a hidden
//   `.<name>.icloud` stand-in;
// - `unlist(_:)`: a folder listed before its files: its contents go to the
//   side store and it lists empty;
// - `evictFolder(_:as:)`: a folder iCloud Drive holds as one package, evicted
//   whole (Files ▸ "Remove Download"): `.standIn` leaves only a hidden
//   `.<name>.icloud` in the folder above, `.dataless` keeps the folder,
//   listed without its files. When it comes back and a folder was made under
//   its name meanwhile, it lands beside it as `<name> 2` (iCloud's split copy);
// - `requestDownload` brings an item back after `arrivalDelay` provider
//   operations (0: at once); `fail(_:_:)` makes it report a download error;
// - `addConflict(_:_:)`: a conflict version of a file, kept in the side store
//   until resolved;
// - `announce(_:)`: a change hint on every `changes(below:)` stream;
// - coordinated reads and writes are counted.
//
// Paths are relative to `root`, `/`-separated. Foundation only.

/// A simulated provider (see above).
public final class EvictingFolderProvider: FolderProvider, @unchecked Sendable {
    /// How a file is evicted.
    public enum Eviction: Sendable, Hashable {
        /// Under its real name, with its size, and no bytes (zeros on disk here).
        case dataless
        /// Replaced by a hidden `.<name>.icloud` stand-in.
        case standIn
    }

    /// The folder it manages (symbolic links resolved).
    public let root: URL
    /// Where evicted bytes, unlisted folders' contents and conflict versions are kept (outside `root`).
    public let cloud: URL

    private let lock = NSLock()
    private var evicted: [String: Eviction] = [:]
    /// Folders evicted whole as a stand-in (`evictFolder`).
    private var evictedFolders = Set<String>()
    private var unlisted = Set<String>()
    /// Where each unlisted folder's contents are kept meanwhile.
    private var unlistedStore: [String: URL] = [:]
    private var pending: [String: Int] = [:]
    private var failures: [String: String] = [:]
    private var versionStore: [String: [(version: RemoteVersion, file: URL)]] = [:]
    private var streams: [UUID: AsyncStream<RemoteChange>.Continuation] = [:]
    private var _arrivalDelay = 0
    private var _coordinatedReads = 0, _coordinatedWrites = 0
    private var _requested: [String] = []

    public init(root: URL, cloud: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.cloud = cloud
    }

    public var name: String { "a simulated provider" }
    public var managesFiles: Bool { true }

    /// Provider operations before a requested item arrives (0: at once).
    public var arrivalDelay: Int {
        get { withLock { _arrivalDelay } }
        set { withLock { _arrivalDelay = max(newValue, 0) } }
    }
    /// Coordinated reads and writes so far.
    public var coordinatedReads: Int { withLock { _coordinatedReads } }
    public var coordinatedWrites: Int { withLock { _coordinatedWrites } }
    /// Every path asked for, in order.
    public var requested: [String] { withLock { _requested } }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func rel(_ url: URL) -> String? {
        let base = root.pathComponents
        let parts = Self.resolved(url).pathComponents
        guard parts.count >= base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// `url` with symbolic links resolved in the part that exists (an evicted folder is not there to resolve).
    private static func resolved(_ url: URL) -> URL {
        var head = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: head.path), head.pathComponents.count > 1 {
            tail.insert(head.lastPathComponent, at: 0)
            head = head.deletingLastPathComponent()
        }
        return tail.reduce(head.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    private func local(_ rel: String) -> URL { rel.isEmpty ? root : root.appendingPathComponent(rel) }
    private func stored(_ rel: String) -> URL { cloud.appendingPathComponent("files").appendingPathComponent(rel) }
    private func storedFolder(_ rel: String) -> URL {
        cloud.appendingPathComponent("folders").appendingPathComponent(rel.isEmpty ? "root" : rel)
    }

    private static func makeParent(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    // MARK: Simulating

    /// Evicts the file at `rel` (see above).
    public func evict(_ rel: String, as kind: Eviction = .dataless) throws {
        try withLock {
            let file = local(rel)
            let data = try Data(contentsOf: file)
            let keep = stored(rel)
            try Self.makeParent(keep)
            try? FileManager.default.removeItem(at: keep)
            try data.write(to: keep)
            switch kind {
            case .dataless:
                try Data(count: data.count).write(to: file)
            case .standIn:
                try FileManager.default.removeItem(at: file)
                let standIn = file.deletingLastPathComponent()
                    .appendingPathComponent(UbiquitousPlaceholder.standInName(for: file.lastPathComponent))
                try Data("bplist00 stand-in".utf8).write(to: standIn)
            }
            evicted[rel] = kind
            pending[rel] = nil
        }
    }

    /// Makes the folder at `rel` list as empty, its contents elsewhere, until asked for.
    public func unlist(_ rel: String) throws {
        try withLock {
            let dir = local(rel)
            let keep = cloud.appendingPathComponent("unlisted").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
            unlistedStore[rel] = keep
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                try FileManager.default.moveItem(at: dir.appendingPathComponent(name), to: keep.appendingPathComponent(name))
            }
            unlisted.insert(rel)
            pending[rel] = nil
        }
    }

    /// Evicts the folder at `rel` whole, as iCloud Drive evicts a package (see above). `rel` may be "" (the
    /// provider's root itself: a target that is the package).
    public func evictFolder(_ rel: String, as kind: Eviction = .standIn) throws {
        if kind == .dataless { return try unlist(rel) }
        try withLock {
            let dir = local(rel)
            let keep = storedFolder(rel)
            try Self.makeParent(keep)
            try? FileManager.default.removeItem(at: keep)
            try FileManager.default.moveItem(at: dir, to: keep)
            let standIn = dir.deletingLastPathComponent().appendingPathComponent(UbiquitousPlaceholder.standInName(for: dir.lastPathComponent))
            try Data("bplist00 package stand-in".utf8).write(to: standIn)
            evicted[rel] = .standIn
            evictedFolders.insert(rel)
            pending[rel] = nil
        }
    }

    /// Where a folder evicted whole came back beside a folder made under its name meanwhile (`<name> 2`), nil when
    /// none did: the split copy a run must never cause.
    public func splitCopy(of rel: String) -> URL? {
        let dir = local(rel)
        let ext = dir.pathExtension
        let stem = dir.deletingPathExtension().lastPathComponent
        let copy = dir.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(stem) 2" : "\(stem) 2.\(ext)")
        return FileManager.default.fileExists(atPath: copy.path) ? copy : nil
    }

    /// The item at `rel` reports a download error (`why`), or none (nil).
    public func fail(_ rel: String, _ why: String?) {
        withLock { failures[rel] = why }
    }

    /// Whether the file at `rel` is evicted, or the folder at `rel` unlisted.
    public func isAway(_ rel: String) -> Bool { withLock { evicted[rel] != nil || unlisted.contains(rel) } }

    /// Adds a conflict version of the file at `rel` holding `data`.
    @discardableResult
    public func addConflict(_ rel: String, _ data: Data, modified: Date? = nil, device: String? = nil) throws -> RemoteVersion {
        try withLock {
            let id = UUID().uuidString.lowercased()
            let file = cloud.appendingPathComponent("versions").appendingPathComponent(id)
            try Self.makeParent(file)
            try data.write(to: file)
            let v = RemoteVersion(id: id, modified: modified, device: device)
            versionStore[rel, default: []].append((v, file))
            return v
        }
    }

    /// The conflict versions the file at `rel` still has.
    public func versions(of rel: String) -> [RemoteVersion] { withLock { versionStore[rel]?.map(\.version) ?? [] } }

    /// Hands `change` to every `changes(below:)` stream.
    public func announce(_ change: RemoteChange) {
        for c in withLock({ Array(streams.values) }) { c.yield(change) }
    }

    /// One provider operation: requested items move towards arriving. The lock is held.
    private func tick() {
        for (rel, left) in pending {
            if left <= 1 {
                pending[rel] = nil
                arrive(rel)
            } else {
                pending[rel] = left - 1
            }
        }
    }

    /// Brings an evicted file or unlisted folder back. The lock is held.
    private func arrive(_ rel: String) {
        let fm = FileManager.default
        if evictedFolders.remove(rel) != nil {
            evicted[rel] = nil
            let dir = local(rel)
            try? fm.removeItem(at: dir.deletingLastPathComponent()
                .appendingPathComponent(UbiquitousPlaceholder.standInName(for: dir.lastPathComponent)))
            // A folder made under its name meanwhile: iCloud keeps both, the package as `<name> 2`.
            var dest = dir
            if fm.fileExists(atPath: dir.path) {
                let ext = dir.pathExtension, stem = dir.deletingPathExtension().lastPathComponent
                dest = dir.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(stem) 2" : "\(stem) 2.\(ext)")
            }
            try? fm.moveItem(at: storedFolder(rel), to: dest)
            return
        }
        if let kind = evicted.removeValue(forKey: rel) {
            let file = local(rel)
            if kind == .standIn {
                try? fm.removeItem(at: file.deletingLastPathComponent()
                    .appendingPathComponent(UbiquitousPlaceholder.standInName(for: file.lastPathComponent)))
            }
            // rename(2) over the zeros: the whole file appears at once, never missing meanwhile.
            let from = stored(rel)
            _ = from.withUnsafeFileSystemRepresentation { src in
                file.withUnsafeFileSystemRepresentation { dst -> Int32 in
                    guard let src, let dst else { return -1 }
                    return rename(src, dst)
                }
            }
        }
        if unlisted.remove(rel) != nil, let keep = unlistedStore.removeValue(forKey: rel) {
            let dir = local(rel)
            for name in (try? fm.contentsOfDirectory(atPath: keep.path)) ?? [] {
                try? fm.moveItem(at: keep.appendingPathComponent(name), to: dir.appendingPathComponent(name))
            }
        }
    }

    // MARK: FolderProvider

    public func standInRealName(_ name: String) -> String? { UbiquitousPlaceholder.realName(of: name) }

    public func availability(of url: URL, stat: FolderItemStat) -> RemoteAvailability {
        withLock {
            tick()
            guard let rel = rel(url) else { return .available }
            if let why = failures[rel] { return .failed(why) }
            guard evicted[rel] != nil || unlisted.contains(rel) else { return .available }
            return pending[rel] != nil ? .downloading : .remoteOnly
        }
    }

    public func requestDownload(_ url: URL) throws {
        withLock {
            guard let rel = rel(url) else { return }
            _requested.append(rel)
            tick()
            guard failures[rel] == nil, evicted[rel] != nil || unlisted.contains(rel) else { return }
            if _arrivalDelay == 0 {
                pending[rel] = nil
                arrive(rel)
            } else if pending[rel] == nil {
                pending[rel] = _arrivalDelay
            }
        }
    }

    public func coordinatedRead<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        withLock { _coordinatedReads += 1; tick() }
        return try body()
    }

    public func coordinatedWrite<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        withLock { _coordinatedWrites += 1; tick() }
        return try body()
    }

    public func conflictVersions(of url: URL) -> [RemoteVersion] {
        withLock { rel(url).flatMap { versionStore[$0]?.map(\.version) } ?? [] }
    }

    public func versionFile(of url: URL, id: String) -> URL? {
        withLock { rel(url).flatMap { versionStore[$0]?.first { $0.version.id == id }?.file } }
    }

    public func resolveConflicts(of url: URL, ids: Set<String>) throws {
        withLock {
            guard let rel = rel(url) else { return }
            let (gone, kept) = (versionStore[rel] ?? []).reduce(into: ([URL](), [(version: RemoteVersion, file: URL)]())) {
                if ids.contains($1.version.id) { $0.0.append($1.file) } else { $0.1.append($1) }
            }
            for f in gone { try? FileManager.default.removeItem(at: f) }
            versionStore[rel] = kept.isEmpty ? nil : kept
        }
    }

    public func changes(below root: URL) -> AsyncStream<RemoteChange>? {
        AsyncStream { continuation in
            let id = UUID()
            withLock { streams[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.withLock { self?.streams[id] = nil } }
        }
    }
}
