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
        /// For an entry of `errors`: what kind of failure it is, when it is one that the next run may not see (a
        /// network failure, the run's stop, a provider still downloading). Nil: a lasting problem.
        public var kind: IssueKind?

        public init(path: String, message: String, kind: IssueKind? = nil) {
            self.path = path; self.message = message; self.kind = kind
        }
    }

    /// Errors that say nothing lasting about the vault or the target (offline audit P4, P5).
    public enum IssueKind: String, Codable, Hashable, Sendable {
        /// A request failed for the network (a cut connection, a timeout); or a file held back because one of its
        /// note's attachments failed so.
        case network
        /// The run stopped before its end for a cut the next run continues: a cancellation, its time bound, the link
        /// lost (`stoppedEarly`, `stopReason`). A server bound's stop stays a lasting error.
        case stopped
        /// A file a provider still has not downloaded long after it was asked for (`SyncOptions.arrivalStall`).
        case arrivalStall
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
    /// Attachment blobs this run left for a longer one (offline audit P3, `SyncOptions.largeBlobs`): a recent
    /// connection window cut an upload this large short, so they wait for a run with more time (a background
    /// processing task, Sync Now, `--large-blobs now`), or the run that tries them anyway after a few runs. Their
    /// notes' new revisions wait with them. Not an error: every other file of the run went.
    public var deferred: [Issue] = []
    /// Set when a bound of the run (`SyncLimits`) stopped it early: what was
    /// reached. Also listed in `errors`; the next run continues.
    public var stoppedEarly: String?
    /// Why the run stopped early (`stoppedEarly`), nil when it did not.
    public var stopReason: StopReason?

    /// What stopped a run early (offline audit P4; review of #91, M1).
    public enum StopReason: String, Codable, Hashable, Sendable {
        /// The caller canceled it (iOS taking the background time back).
        case cancelled
        /// Its time bound (`SyncLimits.maxDuration`).
        case timeLimit
        /// The connection was lost (`SyncError.connectionLost`).
        case connectionLost
        /// Another bound of the run (`maxNotes`, `maxEntries`, `maxDownloadBytes`): it guards against a server that
        /// lists or serves without end, so it stays a lasting failure, never progress.
        case bound

        /// A cut that the next run simply continues: a success when the run moved something.
        public var isProgressStop: Bool { self != .bound }

        /// The reason of a run-limit error, given the run's limits; nil for any other error.
        public init?(_ error: Error, limits: SyncLimits) {
            guard let e = error as? SyncError, e.isRunLimit else { return nil }
            switch e {
            case .cancelled: self = .cancelled
            case .connectionLost: self = .connectionLost
            default: self = e == RunBudget.timeExceeded(limits) ? .timeLimit : .bound
            }
        }
    }
    /// True when the run stopped because several requests in a row failed for the network
    /// (`SyncError.connectionLost`, offline audit P8); nil otherwise.
    public var linkLost: Bool?
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
    /// Signs that this device's clock, or another device's, is far off (offline audit P1), when any.
    public var clock: ClockHint?

    /// What a run saw that says a clock is wrong (offline audit P1). Versions of per-device summaries are times
    /// (format.md §12.5): one more than `PublishedSummaries.futureWindow` ahead of this device's clock, signed by its
    /// device, means that device's clock runs ahead, or this one's behind. Such a copy is left where it is (never
    /// replaced by an older one), and read once this device's clock reaches it.
    public struct ClockHint: Codable, Hashable, Sendable {
        /// The devices (8 hex digits) whose summaries file is signed at a time more than the window ahead of this
        /// device's clock, sorted.
        public var devicesAhead: [String] = []
        /// How far the furthest of them is ahead of this device's clock, in seconds.
        public var aheadBy: TimeInterval = 0

        public init(devicesAhead: [String] = [], aheadBy: TimeInterval = 0) {
            self.devicesAhead = devicesAhead; self.aheadBy = aheadBy
        }

        /// True when more than one other device looks ahead: then this device's clock is the likely one to be
        /// behind ("check this device's date and time").
        public var thisDeviceLikelyBehind: Bool { devicesAhead.count >= 2 }
    }

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
        /// While held (waiting): when this device first met the change it waits for (its sighting). Past about a
        /// day, the CLI and app say so (the owner's decision on the review of #86).
        public var heldSince: Date?
        /// Removals this device made as home that a takeover (made while it was away) dropped (offline audit P16): the
        /// devices they removed are listed again. The new home should remove them again if they are to go.
        public var undoneRemovals: [UndoneRemoval]?

        public init() {}
    }

    /// A device this device removed as home, listed again because a takeover dropped that removal (offline audit P16).
    public struct UndoneRemoval: Codable, Hashable, Sendable {
        /// Its id (8 hex digits).
        public var id: String
        /// Its name on the current list (cleaned), nil when the list names none.
        public var name: String?
        /// The epoch of the dropped removal (this device's own, under the chain it followed before).
        public var droppedEpoch: Int

        public init(id: String, name: String?, droppedEpoch: Int) {
            self.id = id; self.name = name; self.droppedEpoch = droppedEpoch
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

    // MARK: How the run went (offline audit P4)

    /// It moved something: uploads, downloads, deletions, merges or replacements.
    public var madeProgress: Bool {
        !uploaded.isEmpty || !downloaded.isEmpty || !deleted.isEmpty || !merged.isEmpty || !replaced.isEmpty
    }

    /// The entries of `errors` that are lasting problems (no `kind`).
    public var lastingErrors: [Issue] { errors.filter { $0.kind == nil } }

    /// The run did not reach its end for a cut the next run continues (a cancel, its time bound, the link lost; not a
    /// server bound), or some of its requests failed for the network: what it did is kept.
    public var cutShort: Bool {
        (stoppedEarly != nil && stopReason?.isProgressStop != false) || errors.contains { $0.kind == .network || $0.kind == .stopped }
    }

    /// How a run went, for a scheduler (`SyncSchedule.finished(at:outcome:)`) and the problems shown
    /// (`WebDAVSyncProblem.from(report:)`): one place, so the app, the CLI and the tests read it alike.
    public struct Outcome: Hashable, Sendable {
        /// No lasting problem: the schedule does not back off. A run cut short (a short window, the link lost)
        /// that moved something is a success; one that moved nothing is not.
        public var success: Bool
        /// It moved something, or left files arriving: the next periodic run comes soon.
        public var changed: Bool
        /// It was cut short (`cutShort`).
        public var incomplete: Bool
        /// It failed only for the network (and moved nothing): the target cannot be reached now.
        public var offline: Bool
    }

    /// See `Outcome`. A vault.json conflict is not judged here (the caller decides whether it is a problem).
    public var outcome: Outcome {
        let lasting = !lastingErrors.isEmpty
        let changed = madeProgress || !arriving.isEmpty
        let incomplete = cutShort
        let network = errors.contains { $0.kind == .network } || linkLost == true
        if lasting { return Outcome(success: false, changed: changed, incomplete: incomplete, offline: false) }
        if incomplete && !madeProgress {
            return Outcome(success: false, changed: changed, incomplete: true, offline: network)
        }
        return Outcome(success: true, changed: changed || incomplete, incomplete: incomplete, offline: false)
    }

    /// True when nothing was transferred, deleted or reported.
    public var isEmpty: Bool {
        uploaded.isEmpty && downloaded.isEmpty && deleted.isEmpty && conflicts.isEmpty && errors.isEmpty && rejected.isEmpty
            && extraneous.isEmpty && overwritten.isEmpty && quarantined.isEmpty && merged.isEmpty && arriving.isEmpty
            && setAside.isEmpty && replaced.isEmpty && epoch?.taken == nil && epoch?.waiting == nil && deferred.isEmpty
    }
}
