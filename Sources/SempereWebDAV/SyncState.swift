import Crypto
import Foundation
import Sempere

/// What the last successful sync left behind, so the next one can tell which
/// side changed. It lives outside the vault (default `$XDG_STATE_HOME/sempere/sync/`)
/// and holds no secrets: file names, hashes, ETags and snapshot coverage.
struct SyncState: Codable, Equatable {
    /// Last-synced version of a mutable file.
    struct MutableRecord: Codable, Equatable {
        /// SHA-256 (hex) of the content both sides had.
        var hash: String
        /// The remote ETag (else Last-Modified) at that time.
        var stamp: String?
    }

    /// A revision file both sides had.
    struct FileRecord: Codable, Equatable {
        /// For a snapshot, what it covered, so a later compaction that removed it can be checked.
        var included: Included?
    }

    /// A blob download that was interrupted: its partial file
    /// (`att/.sempere-tmp-part-<name>`) continues only from the same remote
    /// version.
    struct PartialRecord: Codable, Equatable {
        /// The ETag the download started from (sent as `If-Range`).
        var etag: String
    }

    var version = 1
    var mutable: [String: MutableRecord] = [:]
    /// Keyed `<noteId>/<file name>` for revisions and
    /// `<noteId>/att/<file name>` for blobs.
    var files: [String: FileRecord] = [:]
    /// Interrupted blob downloads, keyed `<noteId>/att/<file name>`.
    /// Optional so state files written before blob sync still decode.
    var partials: [String: PartialRecord]?
    /// Temporary upload names (paths below the collection) this device
    /// created on the server and has not removed yet; the next run deletes them.
    var remoteTemps: [String]?
    /// SHA-256 (hex) of the server listing (`sempere-index.json` bytes, then
    /// 0 and the manifest's sealed vault secret) the server's published
    /// summaries were last written for by this device,
    /// when every note there got an entry (else nil: try again next run).
    var publishedSummaries: String?
    /// Remote files an earlier run downloaded and quarantined (format.md
    /// §9.1), keyed like `files`: not downloaded again while the server's
    /// copy and the local `vault.json` are unchanged.
    var quarantined: [String: QuarantineRecord]?

    /// A quarantined remote file.
    struct QuarantineRecord: Codable, Equatable {
        /// The remote version (ETag, else Last-Modified, else size) that failed.
        var stamp: String?
        /// SHA-256 (hex) of the local `vault.json` it was checked against,
        /// and whether the vault was unlocked: either changing checks it again.
        var manifest: String?
        var unlocked: Bool
    }

    /// The keys of `files` grouped by note: for each note id (the key up to
    /// its first `/`), the rest of each of its keys (`<file name>` for a
    /// revision, `att/<file name>` for a blob). One pass over `files`, so a
    /// run looks a note's records up without scanning every other note's.
    func fileNamesByNote() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for key in files.keys {
            guard let slash = key.firstIndex(of: "/") else { continue }
            out[String(key[..<slash]), default: []].append(String(key[key.index(after: slash)...]))
        }
        return out
    }

    /// The default state file for one (remote, local vault) pair.
    static func defaultURL(remote: URL, vault: URL,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        let base: URL
        if let xdg = environment["XDG_STATE_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home.appendingPathComponent(".local/state", isDirectory: true)
        }
        let key = remote.absoluteString + "\n" + vault.standardizedFileURL.path
        let id = Hex.encode(SHA256.hash(data: Data(key.utf8)).prefix(8))
        return base.appendingPathComponent("sempere/sync/\(id).json")
    }

    /// Nil when there is no state file; throws when it exists but is unreadable.
    static func load(_ url: URL) throws -> SyncState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try BoundedRead.contents(of: url, maxBytes: BoundedRead.maxRevisionBytes)
        let state = try JSONDecoder().decode(SyncState.self, from: data)
        guard state.version == 1 else { throw WebDAVError.io("sync state \(url.path) has version \(state.version)") }
        return state
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalFS.write(try enc.encode(self), to: url, replacing: true)
    }
}
