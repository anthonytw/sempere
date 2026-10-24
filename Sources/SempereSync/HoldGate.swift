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
    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }

    /// Throws when `path` may not be written now.
    func check(_ path: [String], _ verb: String) throws {
        switch mode {
        case .open: return
        case .epochsOnly where path.first == Vault.epochsName: return
        default:
            throw SyncError.io("not \(verb) \(path.joined(separator: "/")): this run is held back by a device change "
                + "(design §4.3, §5.5), it uploads nothing")
        }
    }
}

/// `base`, with every change refused while `gate` holds the run.
struct HoldGatedRemote: SyncRemote {
    var base: any SyncRemote
    let gate: HoldGate

    var location: String { base.location }
    var capabilities: RemoteCapabilities { base.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { base.interrupt }
        set { base.interrupt = newValue }
    }

    func list(_ path: [String]) throws -> [RemoteEntry]? { try base.list(path) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { try base.listTree(path, maxBytes: maxBytes) }
    func stat(_ path: [String]) throws -> RemoteEntry? { try base.stat(path) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) { try base.read(path, maxBytes: maxBytes) }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                  segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try base.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                          segmentBytes: segmentBytes, progress: progress)
    }
    func requestDownload(_ paths: [[String]]) throws { try base.requestDownload(paths) }
    func conflictVersions(_ path: [String]) -> [RemoteVersion] { base.conflictVersions(path) }
    func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try base.readVersion(path, version, maxBytes: maxBytes)
    }
    func changes() -> AsyncStream<RemoteChange>? { base.changes() }
    func missingCollectionError(_ path: [String]) -> any Error { base.missingCollectionError(path) }

    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        try gate.check(path, "uploaded")
        return try base.write(path, body, condition: condition)
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try gate.check(destination, "moved")
        return try base.moveNoOverwrite(path, to: destination)
    }
    func makeCollection(_ path: [String]) throws -> CollectionResult {
        try gate.check(path, "created")
        return try base.makeCollection(path)
    }
    func createBase() throws {
        try gate.check([], "created")
        try base.createBase()
    }
    func delete(_ path: [String], ifETag: String?) throws -> Bool {
        try gate.check(path, "deleted")
        return try base.delete(path, ifETag: ifETag)
    }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws {
        try gate.check(path, "resolved")
        try base.resolveConflicts(path, versions)
    }
}
