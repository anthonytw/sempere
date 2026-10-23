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
    /// Files and folders a provider lists but has not downloaded yet (evicted
    /// iCloud files, folders listed before their files: `Arrivals.swift`):
    /// asked for, waited for a bounded time, and left for a later run. Never
    /// taken as missing, deleted or uploaded over. One still arriving long after
    /// this device first asked for it is listed in `errors` instead.
    public var arriving: [Issue] = []
    /// Set when a bound of the run (`SyncLimits`) stopped it early: what was
    /// reached. Also listed in `errors`; the next run continues.
    public var stoppedEarly: String?
    /// How far the run got (`SyncProgress`, stage `done`): notes listed
    /// and synced, files and bytes downloaded of those it found to download, uploads.
    public var progress: SyncProgress?
    /// What the run wrote in the local vault folder (`LocalChanges`): set by `SyncEngine.run`.
    public var changed: LocalChanges?
    /// Set when the local folder is a partial copy (format.md §1.2): what it
    /// still lacks after the run, and what a push-only run left on the server
    /// because the copy has not fetched it yet.
    public var partial: PartialStatus?
    /// Remote files under an earlier epoch's key that the acceptance rule does not take (key-hierarchy design
    /// §5.3 rule 4): kept in this device's set-aside store, never placed (KH4).
    public var setAside: [Issue] = []
    /// Remote files that no key this device holds opens while a device-change record has not arrived (§5.3
    /// rule 3): neither placed nor quarantined, tried again once the record (or a new `vault.json`) arrives.
    public var pending: [Issue] = []
    /// Paths whose unaccepted copy (an old-key copy that is not sealed, or under a dropped epoch's key) was
    /// replaced by the accepted copy, on the remote or here, after it was set aside (design §5.4 step 4).
    public var replaced: [Deletion] = []
    /// What the run found about device changes (KH4), when anything.
    public var epoch: EpochStatus?

    /// Device changes as one run met them (key-hierarchy design §4.3, §5.5).
    public struct EpochStatus: Codable, Hashable, Sendable {
        /// The epoch this run took (a removal, a handoff, a takeover, a kit replacement), when it took one.
        public var taken: Int?
        /// The taken epoch's record has not arrived yet: files under the older key are pending.
        public var recordPending = false
        /// Files of this device re-encrypted under the taken key (catch-up, design §5.4).
        public var caughtUp: Int?
        /// A later epoch this device cannot verify yet (unverified-pending): why and where. Nothing new is
        /// uploaded (J5b) until it is verified.
        public var waiting: String?
        /// This device is not on the newest device list it verified (design §5.5): who removed it. It
        /// uploads nothing and keeps pulling.
        public var unlisted: String?
        /// While unlisted: this device's own changes that the target does not hold (its write ledger's files
        /// whose path the target lacks).
        public var unsyncedChanges: Int?
        /// A home conflict or another `vault.json` this device does not follow.
        public var conflict: String?

        public init() {}
    }

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
            && extraneous.isEmpty && overwritten.isEmpty && quarantined.isEmpty && merged.isEmpty && arriving.isEmpty
            && setAside.isEmpty && replaced.isEmpty && epoch?.taken == nil && epoch?.waiting == nil
    }
}
