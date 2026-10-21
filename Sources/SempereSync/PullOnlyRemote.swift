import Foundation

/// A remote that is only ever read (`SyncOptions.pullOnly`, review of #77, S1): every write, move, folder
/// creation, deletion and conflict resolution is dropped before it reaches the wrapped remote, and reported
/// to the engine as done, so a pull-only run downloads what the remote has and changes nothing there. Used
/// for a locked vault's staging (`LockedStaging`): its shadow's files must never be uploaded over newer
/// ones (another device's `settings.age`, a key change's `vault.json` or journal).
struct PullOnlyRemote: SyncRemote {
    var base: any SyncRemote

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

    // Never reaches the remote.
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool { true }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool { true }
    func makeCollection(_ path: [String]) throws -> CollectionResult { .exists }
    func createBase() throws {}
    func delete(_ path: [String], ifETag: String?) throws -> Bool { true }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws {}
}
