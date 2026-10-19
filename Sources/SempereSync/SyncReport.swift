import Foundation

/// What one sync did, or with `dryRun` what it would do.
public struct SyncReport: Codable, Hashable, Sendable {
    /// A deletion and the side it happened on.
    public struct Deletion: Codable, Hashable, Sendable {
        /// `"local"` or `"remote"`.
        public var side: String
        /// Path relative to the vault root.
        public var path: String

        public init(side: String, path: String) { self.side = side; self.path = path }
    }

    /// A mutable file that changed on both sides.
    public struct Conflict: Codable, Hashable, Sendable {
        public var path: String
        /// The remote version, kept next to the local one as this file in the
        /// vault root; nil in a dry run or when an identical copy already existed.
        public var remoteCopy: String?
        public var detail: String

        public init(path: String, remoteCopy: String?, detail: String) {
            self.path = path; self.remoteCopy = remoteCopy; self.detail = detail
        }
    }

    /// A path and a one-line message.
    public struct Issue: Codable, Hashable, Sendable {
        public var path: String
        public var message: String

        public init(path: String, message: String) { self.path = path; self.message = message }
    }

    public var dryRun = false
    /// Paths (relative to the vault root) sent to the server.
    public var uploaded: [String] = []
    /// Paths written locally.
    public var downloaded: [String] = []
    public var deleted: [Deletion] = []
    public var conflicts: [Conflict] = []
    public var errors: [Issue] = []
    /// Things that could not be decided and were left alone (e.g. a deletion
    /// that could not be checked against the compaction rules).
    public var skipped: [Issue] = []
    /// Remote entries whose names are not vault files; never downloaded.
    public var ignored: [String] = []
    /// Push-only runs: files the server holds that the local vault does not
    /// and that no compaction explains (never synced before, e.g. injected by
    /// the server). Listed whether or not `--delete-extraneous` removed them.
    public var extraneous: [String] = []
    /// Push-only runs: mutable files (`vault.json`, `rewrap-journal.json`)
    /// whose different server copy was replaced by the local one. Also in `uploaded`.
    public var overwritten: [String] = []
    /// Files changed on both sides whose copies were merged rather than kept
    /// apart: `settings.age` (format.md §13). The result is written to both sides.
    public var merged: [String] = []
    /// Remote files that were not taken because they failed a check: a
    /// `vault.json` whose device list changed without a valid tag (format.md
    /// §2.1). The local copy stays; nothing is uploaded over the remote one.
    public var rejected: [Issue] = []
    /// Remote revisions and blobs that were downloaded but failed the checks
    /// before placing (format.md §9.1): not written to the vault, kept in
    /// the quarantine folder (`quarantineDirectory`), and not downloaded
    /// again while unchanged (then listed in `skipped`).
    public var quarantined: [Issue] = []
    /// Set when a bound of the run (`SyncLimits`) stopped it early: what was
    /// reached. Also listed in `errors`; the next run continues.
    public var stoppedEarly: String?
    /// How far the run got (`WebDAVSyncProgress`, stage `done`): notes listed
    /// and synced, files and bytes downloaded of those it found to download, uploads.
    public var progress: WebDAVSyncProgress?
    /// Set when the local folder is a partial copy (format.md §1.2): what it
    /// still lacks after the run, and what a push-only run left on the server
    /// because the copy has not fetched it yet.
    public var partial: PartialStatus?

    /// What a partial copy lacks (docs/io.md "Partial copies").
    public struct PartialStatus: Codable, Hashable, Sendable {
        /// Notes whose revisions have not all arrived.
        public var incompleteNotes = 0
        /// Blobs not fetched yet (stand-ins).
        public var pendingBlobs = 0
        /// Push-only: server files kept because the copy has not fetched them
        /// (never deleted there, never extraneous).
        public var keptOnServer = 0
        /// True when this run fetched the last of it: the copy is complete.
        public var completed = false

        public init(incompleteNotes: Int = 0, pendingBlobs: Int = 0, keptOnServer: Int = 0, completed: Bool = false) {
            self.incompleteNotes = incompleteNotes; self.pendingBlobs = pendingBlobs
            self.keptOnServer = keptOnServer; self.completed = completed
        }
    }

    public init(dryRun: Bool = false) { self.dryRun = dryRun }

    /// `text` with control characters escaped as `\u{XX}`, so a name or
    /// header chosen by the server cannot drive the terminal it is printed on.
    public static func printable(_ text: String) -> String {
        var out = ""
        for u in text.unicodeScalars {
            if u.properties.generalCategory == .control {
                out += "\\u{" + String(u.value, radix: 16, uppercase: true) + "}"
            } else {
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// True when nothing was transferred, deleted or reported.
    public var isEmpty: Bool {
        uploaded.isEmpty && downloaded.isEmpty && deleted.isEmpty && conflicts.isEmpty && errors.isEmpty && rejected.isEmpty
            && extraneous.isEmpty && overwritten.isEmpty && quarantined.isEmpty && merged.isEmpty
    }
}
