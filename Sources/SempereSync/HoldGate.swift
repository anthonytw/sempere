import Foundation
import Sempere

// A held run uploads nothing (design §4.3 J5b, §5.5; review of #86, M2): every write, move, collection,
// deletion and conflict resolution of the run goes through `HoldGatedRemote`, which refuses it while the run
// is held. A waiting device may still sync `epochs/` (the record it waits for may be on its way); an unlisted
// one writes nothing at all. One gate for every path, so a step that forgets to check the hold cannot upload.

/// What a held run may still write to the target.
final class HoldGate: @unchecked Sendable {
    enum Mode: Sendable { case open, epochsOnly, nothing }
    private let lock = NSLock()
    private var _mode: Mode = .open
    private var _joining = false
    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }
    /// A run of a device that has not joined yet (no vault key, its own key given to take the approval): it writes
    /// only its join request (`joins/`) until it confirms, whatever its copy holds (review of #90, S2).
    var joining: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _joining }
        set { lock.lock(); _joining = newValue; lock.unlock() }
    }

    /// The end of every refusal of a joining run (`joining`): a run reports them as one waiting line, not as errors.
    static let joiningRefusal = "this device has not joined the vault yet; it sends only its join request"

    /// Throws when `path` may not be written now.
    func check(_ path: [String], _ verb: String) throws {
        if joining, path.first != Vault.joinsName {
            throw SyncError.io("not \(verb) \(path.joined(separator: "/")): " + Self.joiningRefusal)
        }
        switch mode {
        case .open: return
        case .epochsOnly where path.first == Vault.epochsName: return
        default:
            throw SyncError.io("not \(verb) \(path.joined(separator: "/")): this run is held back by a device change "
                + "(design §4.3, §5.5), it uploads nothing")
        }
    }
}

/// `base`, with every change refused while `gate` holds the run, and every request counted by `breaker`
/// (`LinkBreaker.swift`: a dead link stops the run).
struct HoldGatedRemote: SyncRemote {
    var base: any SyncRemote
    let gate: HoldGate
    var breaker = LinkBreaker()

    var location: String { base.location }
    var capabilities: RemoteCapabilities { base.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { base.interrupt }
        set { base.interrupt = newValue }
    }

    func list(_ path: [String]) throws -> [RemoteEntry]? { try breaker.run { try base.list(path) } }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? {
        try breaker.run { try base.listTree(path, maxBytes: maxBytes) }
    }
    func stat(_ path: [String]) throws -> RemoteEntry? { try breaker.run { try base.stat(path) } }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        try breaker.run { try base.read(path, maxBytes: maxBytes) }
    }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                  segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try breaker.run {
            try base.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                              segmentBytes: segmentBytes, progress: progress)
        }
    }
    func requestDownload(_ paths: [[String]]) throws { try breaker.run { try base.requestDownload(paths) } }
    func conflictVersions(_ path: [String]) -> [RemoteVersion] { base.conflictVersions(path) }
    func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try breaker.run { try base.readVersion(path, version, maxBytes: maxBytes) }
    }
    func changes() -> AsyncStream<RemoteChange>? { base.changes() }
    func missingCollectionError(_ path: [String]) -> any Error { base.missingCollectionError(path) }
    func checkAbsentBase(syncedBefore: Bool) throws { try breaker.run { try base.checkAbsentBase(syncedBefore: syncedBefore) } }

    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        try gate.check(path, "uploaded")
        return try breaker.run { try base.write(path, body, condition: condition) }
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try gate.check(destination, "moved")
        return try breaker.run { try base.moveNoOverwrite(path, to: destination) }
    }
    func makeCollection(_ path: [String]) throws -> CollectionResult {
        try gate.check(path, "created")
        return try breaker.run { try base.makeCollection(path) }
    }
    func createBase() throws {
        try gate.check([], "created")
        try breaker.run { try base.createBase() }
    }
    func delete(_ path: [String], ifETag: String?) throws -> Bool {
        try gate.check(path, "deleted")
        return try breaker.run { try base.delete(path, ifETag: ifETag) }
    }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws {
        try gate.check(path, "resolved")
        try breaker.run { try base.resolveConflicts(path, versions) }
    }
}
