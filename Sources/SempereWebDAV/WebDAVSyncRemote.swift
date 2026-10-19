import Age
import Foundation
import Sempere
import SempereSync

/// A WebDAV collection as the remote of a sync (`SyncRemote`): the engine's
/// operations as `WebDAVClient` requests (PROPFIND, GET, PUT, MOVE, MKCOL,
/// DELETE). No networking here: the client and its transport make the requests.
public struct WebDAVSyncRemote: SyncRemote {
    /// The client; the engine sets its `interrupt` through `interrupt` below.
    public private(set) var client: WebDAVClient

    public init(_ client: WebDAVClient) { self.client = client }

    public var location: String { client.baseURL.absoluteString }

    /// What WebDAV gives at best. The engine still checks each server: deep
    /// listings and folder ETags are trusted only where seen to work
    /// (`TreeListing.swift`, `NoteStamps.swift`), weak ETags never back a condition.
    public var capabilities: RemoteCapabilities {
        [.strongStamps, .rangeReads, .deepListing, .folderStampsTrackChildren, .createViaTemporaryName]
    }

    public var interrupt: (@Sendable () -> (any Error)?)? {
        get { client.interrupt }
        set { client.interrupt = newValue }
    }

    public func list(_ path: [String]) throws -> [RemoteEntry]? { try client.list(path) }

    public func listTree(_ path: [String]) throws -> RemoteTree? {
        switch try client.listTree(path) {
        case .listed(let tree)?: return .listed(tree)
        case .refused?: return .refused
        case nil: return nil
        }
    }

    public func stat(_ path: [String]) throws -> RemoteEntry? { try client.stat(path) }

    public func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        try client.get(path, maxBytes: maxBytes)
    }

    /// `Range` requests of `segmentBytes`, resumed with `If-Range`; a
    /// server that answers 416 to a resumed download (the partial file does
    /// not fit the remote one) gets the whole file again, from byte 0.
    @discardableResult
    public func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                         segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> RemoteDownload {
        let got: WebDAVClient.Download
        do {
            got = try client.download(path, to: file, resumeFrom: resumeFrom, ifRange: ifETag, maxBytes: maxBytes,
                                      segmentBytes: segmentBytes, progress: progress)
        } catch WebDAVError.http(_, _, 416) where resumeFrom > 0 {
            // The partial file does not fit the remote one: start over.
            try? FileManager.default.removeItem(at: file)
            got = try client.download(path, to: file, maxBytes: maxBytes, segmentBytes: segmentBytes, progress: progress)
        }
        return RemoteDownload(resumed: got.resumed, etag: got.etag)
    }

    @discardableResult
    public func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        switch body {
        case .data(let data): return try client.put(path, data, condition: condition)
        case .file(let file): return try client.put(path, fromFile: file, condition: condition)
        }
    }

    /// `MOVE` with `Overwrite: F`.
    @discardableResult
    public func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try client.move(path, to: destination, overwrite: false)
    }

    public func makeCollection(_ path: [String]) throws -> CollectionResult {
        switch try client.mkcol(path) {
        case .created: return .created
        case .exists: return .exists
        case .missingParent: return .missingParent
        }
    }

    public func createBase() throws { try client.createBase() }

    @discardableResult
    public func delete(_ path: [String], ifETag: String?) throws -> Bool { try client.delete(path, ifMatch: ifETag) }

    /// What a `PROPFIND` of the missing collection answered: a 404.
    public func missingCollectionError(_ path: [String]) -> any Error {
        WebDAVError.http(method: "PROPFIND", path: path.joined(separator: "/"), status: 404)
    }
}

// MARK: - The engine over a WebDAV client

extension SyncEngine {
    /// A sync of `directory` with the WebDAV collection of `client` (`WebDAVSyncRemote`).
    public convenience init(directory: URL, vault: Vault?, client: WebDAVClient, stateURL: URL,
                            options: SyncOptions = SyncOptions()) {
        self.init(directory: directory, vault: vault, remote: WebDAVSyncRemote(client), stateURL: stateURL, options: options)
    }
}

extension LocalCopy {
    /// `download(remote:options:)` from a WebDAV collection.
    public func download(client: WebDAVClient, options: SyncOptions = SyncOptions()) throws -> SyncReport {
        try download(remote: WebDAVSyncRemote(client), options: options)
    }

    /// `downloadMetadata(remote:options:)` from a WebDAV collection.
    public func downloadMetadata(client: WebDAVClient, options: SyncOptions = SyncOptions()) throws -> SyncReport {
        try downloadMetadata(remote: WebDAVSyncRemote(client), options: options)
    }

    /// `fetch(remote:vault:scope:options:)` from a WebDAV collection.
    public func fetch(client: WebDAVClient, vault: Vault?, scope: FetchScope = FetchScope(),
                      options: SyncOptions = SyncOptions()) throws -> SyncReport {
        try fetch(remote: WebDAVSyncRemote(client), vault: vault, scope: scope, options: options)
    }

    /// `push(remote:vault:options:)` to a WebDAV collection.
    public func push(client: WebDAVClient, vault: Vault?, options: SyncOptions = SyncOptions()) throws -> SyncReport {
        try push(remote: WebDAVSyncRemote(client), vault: vault, options: options)
    }

    /// `redownload(remote:identities:partial:options:)` from a WebDAV collection.
    public func redownload(client: WebDAVClient, identities: [any AgeIdentity], partial: Bool = false,
                           options: SyncOptions = SyncOptions()) throws -> (report: SyncReport, replaced: Bool) {
        try redownload(remote: WebDAVSyncRemote(client), identities: identities, partial: partial, options: options)
    }
}
