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
    /// Set when the local folder is a partial copy (format.md §1.2): what it
    /// still lacks after the run, and what a push-only run left on the server
    /// because the copy has not fetched it yet.
    public var partial: PartialStatus?
    /// What the run did for key changes (design §6); nil when it did nothing.
    public var keyChange: KeyChangeActivity?

    /// Key-change work of one run (docs/design/device-first-sync.md §5.2, §6).
    public struct KeyChangeActivity: Codable, Hashable, Sendable {
        /// Files replaced by rewrap-replace (design §5.2), with the side replaced.
        public var replaced: [Deletion] = []
        /// Late files (tagged under an older secret, design §6.2 F9) taken in
        /// within the window: rewrapped and placed.
        public var lateAccepted: [LateFile] = []
        /// Late files after the window (or of a change whose policy is
        /// unknown here): quarantined as late files, never deleted.
        public var lateQuarantined: [Issue] = []
        /// Local files rewrapped from this device's keyring (R3).
        public var rewrapped = 0
        /// Shared files whose two copies differ and stay as they are this run.
        public var unsettled: [Issue] = []
        /// Shared files under an older wrap on both sides that this device cannot make current (another
        /// device's): kept as they are until their writer or a current copy replaces them.
        public var staleKept: [String] = []
        /// The remote gives no strong version tokens, so no copy there is replaced (rewrap-replace needs
        /// `If-Match`): a key change never finishes on it (C5(d) waits). Reported, never worked around.
        public var weakStamps = false
        /// The keyring cannot be read: this run went on without it. Repair: `SealedFileKeyringStore.setAside`.
        public var keyringProblem: String?
        /// True when this run found every file both sides hold current and
        /// the same on both, under the same list (what lets a key change
        /// remove the journal from this target, design §6.1 C5(d)).
        public var settled = false
        /// The remote `vault.json` lists none of this device's keys: it was removed.
        public var removedFromVault = false

        public init() {}

        var isEmpty: Bool { replaced.isEmpty && lateAccepted.isEmpty && lateQuarantined.isEmpty && rewrapped == 0 }
    }

    /// A late file taken in, and the end of the window it was taken in under.
    public struct LateFile: Codable, Hashable, Sendable {
        public var path: String
        public var deadline: Date
        /// The `secretId` (format.md §2.1, hex) of the older secret it was tagged under.
        public var secretId: String?
        public init(path: String, deadline: Date, secretId: String? = nil) {
            self.path = path; self.deadline = deadline; self.secretId = secretId
        }
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
            && (keyChange?.isEmpty ?? true)
    }
}
