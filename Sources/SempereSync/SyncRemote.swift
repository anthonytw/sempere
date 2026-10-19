import Foundation

// MARK: - The remote side of a sync (docs/io.md "Sync engine and transports")
//
// `SyncEngine` keeps a local vault folder and a *remote* in step. A remote is
// anything that stores a copy of the vault layout below one base collection:
// a WebDAV collection today (`WebDAVSyncRemote` in SempereWebDAV), and later a
// plain or provider-managed folder (iCloud Drive, another File Provider), an
// in-memory store for tests, or a first-class integration such as an
// S3-compatible bucket or Dropbox (docs/design/device-first-sync.md §3.2).
//
// The engine owns every rule (what is copied, checked, quarantined, deleted
// and recorded); a transport only moves bytes and reports what is there. So
// the protocol is the handful of operations the engine makes, with
// transport-neutral names, plus hooks that only some stores need (eviction,
// conflict versions, change hints). Its contract:
//
// - Paths are component lists below the remote's base (`[]` is the base
//   itself). The engine builds them only from validated vault names; a
//   transport still refuses a component it cannot represent.
// - Every operation blocks until it is done and may be called from several
//   threads at once (`TransferPool`). A conformer is a value or is
//   internally synchronized.
// - An `etag` (in `RemoteEntry`, `read`, `PutCondition`, `delete`) is a
//   version token: it must change whenever the bytes do. A *strong* one
//   (`SyncEngine.isStrong`: not `W/"…"`, not empty) also backs conditional
//   writes, deletes and resumed downloads; a weak one is only compared.
//   WebDAV uses its ETags; a folder transport would use size + mtime + file id.
// - Everything a remote returns is untrusted (format.md §9): the engine
//   bounds and checks it, and a transport bounds what it reads (`maxBytes`).
// - A failure the next run may not see (no network, a cut connection, a
//   timeout) is an error conforming to `TransientRemoteError` whose
//   `isTransient` is true: the engine then keeps a partial download for the
//   next run instead of discarding it.
//
// Adding a transport: conform a type to `SyncRemote` in its own target (a
// network transport belongs in a network target; `SempereSync` stays
// Foundation-only and network-free), map its failures onto its own error type
// (conforming to `TransientRemoteError`), and pass it to `SyncEngine` or
// `LocalCopy`. The optional hooks keep their defaults unless the store evicts
// files, forks conflict versions or can announce changes.

/// One child of a collection on a remote.
public struct RemoteEntry: Hashable, Sendable {
    public var name: String
    public var isCollection: Bool
    /// The version token of this entry (see the contract above), if the remote has one.
    public var etag: String?
    /// The modification time as the remote reports it (an opaque string), if any.
    public var lastModified: String?
    public var size: Int?

    public init(name: String, isCollection: Bool, etag: String? = nil, lastModified: String? = nil, size: Int? = nil) {
        self.name = name; self.isCollection = isCollection
        self.etag = etag; self.lastModified = lastModified; self.size = size
    }

    /// What identifies this version of the file: the ETag, else the modification time.
    public var stamp: String? { etag ?? lastModified }
}

/// How a write is made conditional.
public enum PutCondition: Sendable, Equatable {
    /// Only create, never replace (WebDAV `If-None-Match: *`).
    case create
    /// Replace only the version with this strong `etag` (WebDAV `If-Match`).
    case replace(etag: String)
    /// No precondition (the remote gave no strong version token).
    case unconditional
}

/// What a write sends.
public enum RemoteBody: Sendable {
    /// Bytes in memory (revisions, root files: bounded by the engine).
    case data(Data)
    /// A file streamed from disk, never held in memory (attachment blobs).
    case file(URL)
}

/// What `SyncRemote.listTree` found below a collection.
public enum RemoteTree: Sendable, Equatable {
    /// The children of every collection below it, keyed by its path relative
    /// to the listed one (`[]` for the listed one itself). A collection the
    /// answer names but whose children it does not list has no key.
    case listed([[String]: [RemoteEntry]])
    /// The remote cannot list a whole tree at once (or answered as if asked
    /// for one level only); the engine lists collection by collection.
    case refused
}

/// What `SyncRemote.download` received.
public struct RemoteDownload: Sendable, Equatable {
    /// True when the bytes already in the file were kept and only the rest
    /// was fetched; false when the file now holds a fresh copy.
    public var resumed: Bool
    /// The version token of what was received, if any.
    public var etag: String?

    public init(resumed: Bool, etag: String?) { self.resumed = resumed; self.etag = etag }
}

/// What `SyncRemote.makeCollection` found.
public enum CollectionResult: Sendable, Equatable {
    case created
    case exists
    /// Its parent does not exist (the engine makes the parent, then retries).
    case missingParent
}

/// What a remote can promise. The engine learns WebDAV's behavior by probing
/// (`TreeListing.swift`, `NoteStamps.swift`), so these are declarations a
/// transport makes up front; the engine reads them as later transports need.
public struct RemoteCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Version tokens are strong (see the contract above) for files.
    public static let strongStamps = RemoteCapabilities(rawValue: 1 << 0)
    /// `download` can resume at an offset.
    public static let rangeReads = RemoteCapabilities(rawValue: 1 << 1)
    /// `listTree` may answer (it is still checked against per-collection listings).
    public static let deepListing = RemoteCapabilities(rawValue: 1 << 2)
    /// A collection's version token changes when a child is written (`skipUnchangedNotes`; still checked).
    public static let folderStampsTrackChildren = RemoteCapabilities(rawValue: 1 << 3)
    /// A large file must be written under a temporary name and moved into
    /// place (`moveNoOverwrite`), because a create-only write of it is not atomic.
    public static let createViaTemporaryName = RemoteCapabilities(rawValue: 1 << 4)
}

/// Whether a listed file's bytes can be read now (stores that evict files).
public enum RemoteAvailability: Sendable, Hashable {
    /// Readable now.
    case available
    /// Listed, but its bytes are elsewhere (an evicted iCloud file): it exists, `requestDownload` it.
    case remoteOnly
    /// Being fetched by the store.
    case downloading
    /// The store reports it cannot fetch it.
    case failed(String)
}

/// Another version of a file that the store keeps beside the current one
/// (iCloud's `NSFileVersion` conflict versions).
public struct RemoteVersion: Sendable, Hashable {
    /// The store's identifier of the version.
    public var id: String
    /// When the store says it was written, if it knows.
    public var modified: Date?
    /// The device the store says wrote it, if it knows (display only).
    public var device: String?

    public init(id: String, modified: Date? = nil, device: String? = nil) {
        self.id = id; self.modified = modified; self.device = device
    }
}

/// A hint that something changed on the remote, so a run is worth starting.
public enum RemoteChange: Sendable, Hashable {
    /// These paths (files or collections) changed.
    case paths([[String]])
    /// Something changed; the remote does not say what.
    case unknown
}

/// A failure of a transport that a later run may not see (no network, a cut
/// connection, a timeout): the engine keeps a partial download for the next
/// run instead of discarding it. Transports' error types conform.
public protocol TransientRemoteError: Error {
    var isTransient: Bool { get }
}

/// The remote side of a sync: the operations `SyncEngine` makes (see the
/// contract at the top of this file).
public protocol SyncRemote: Sendable {
    /// Where the remote is, for messages (a URL, a folder path). Never holds a credential.
    var location: String { get }

    /// What this remote promises; see `RemoteCapabilities`.
    var capabilities: RemoteCapabilities { get }

    /// Asked while a request is in flight: an error it returns stops the
    /// request and is thrown from it. The engine sets it to its run bound and
    /// cancellation for the length of a run.
    var interrupt: (@Sendable () -> (any Error)?)? { get set }

    /// The children of a collection; nil when it does not exist.
    func list(_ path: [String]) throws -> [RemoteEntry]?

    /// Everything below a collection at once; nil when it does not exist,
    /// `.refused` when the remote cannot (the engine then uses `list`).
    func listTree(_ path: [String]) throws -> RemoteTree?

    /// Metadata of one file; nil when it does not exist.
    func stat(_ path: [String]) throws -> RemoteEntry?

    /// The bytes of one file and their version token. Reading stops past
    /// `maxBytes`, with an error.
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?)

    /// Streams one file into `file`, keeping memory bounded (pieces of about
    /// `segmentBytes`, a hint). With `resumeFrom` > 0 and a strong `ifETag`,
    /// the bytes already in `file` up to that offset are kept and only the
    /// rest is fetched, unless the remote file changed (it then comes whole);
    /// a remote that cannot continue at that offset starts over. `progress`
    /// gets the bytes each piece added; what it throws stops the download.
    /// What was written before a failure stays in `file`.
    @discardableResult
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                  segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> RemoteDownload

    /// Writes one file under `condition`; false when the precondition failed
    /// (the file exists, or is not the version expected).
    @discardableResult
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool

    /// Renames a file without ever replacing the destination; false when the destination exists.
    @discardableResult
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool

    /// Creates a collection.
    func makeCollection(_ path: [String]) throws -> CollectionResult

    /// Creates the base collection and any missing ancestors.
    func createBase() throws

    /// Deletes a file; one already gone is fine. With a strong `ifETag`, only
    /// that version is deleted, and false says the file changed and is still there.
    @discardableResult
    func delete(_ path: [String], ifETag: String?) throws -> Bool

    /// The error to report when the collection at `path` (the base: `[]`)
    /// should exist and does not, in the transport's own terms.
    func missingCollectionError(_ path: [String]) -> any Error

    // MARK: Hooks for stores that evict files or fork versions (defaults: nothing to do)

    /// Whether a listed file's bytes are readable now. Default: `.available`.
    func availability(_ path: [String]) -> RemoteAvailability

    /// Asks the store to bring these files' bytes here. Default: nothing.
    func requestDownload(_ paths: [[String]]) throws

    /// Other versions of a file the store keeps beside the current one. Default: none.
    func conflictVersions(_ path: [String]) -> [RemoteVersion]

    /// Removes the versions of `path` that the engine has merged. Default: nothing.
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws

    /// Change hints, for a remote that can announce them; nil: poll only. Default: nil.
    func changes() -> AsyncStream<RemoteChange>?
}

extension SyncRemote {
    public func availability(_ path: [String]) -> RemoteAvailability { .available }
    public func requestDownload(_ paths: [[String]]) throws {}
    public func conflictVersions(_ path: [String]) -> [RemoteVersion] { [] }
    public func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws {}
    public func changes() -> AsyncStream<RemoteChange>? { nil }

    /// Deletes a file, whatever its version.
    @discardableResult
    public func delete(_ path: [String]) throws -> Bool { try delete(path, ifETag: nil) }
}
