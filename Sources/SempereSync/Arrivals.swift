import Foundation
import Sempere

// MARK: - Files a provider has not downloaded yet (docs/io.md "Folder targets in providers")
//
// A remote that keeps files lazily (iCloud Drive, another File Provider,
// `MemoryRemote`'s eviction mode) lists some files whose bytes are elsewhere
// (`RemoteEntry.availability`): evicted files (`.<name>.icloud` stand-ins,
// dataless files) and folders listed before their files. To the engine such a
// file EXISTS but cannot be read now (format.md §1.2 rule 4, applied to the
// remote side; docs/design/device-first-sync.md §3.3):
//
// - it is never taken as dropped, missing or extraneous: it is in the
//   listing, so nothing is uploaded over it and nothing is deleted for it;
// - the files the run would download are asked for in windows
//   (`requestDownload`) as soon as the listings are in, and each read waits for
//   its file, all of them together at most `SyncOptions.arrivalWait` per run;
//   what has not arrived by then is reported in `SyncReport.arriving` and left
//   for a later run (a note with an arriving file records no folder stamp, so
//   the next run lists it again);
// - a file still arriving `arrivalStall` after this device first asked for it
//   is reported in `errors` (the provider may be offline or out of space): a
//   stall is a problem to show, never a reason to give up on the file;
// - a folder listed before its files ("not listed yet": iCloud lists a
//   folder's contents after the folder) is arriving for `unlistedTimeout` from
//   when this device first saw it so: nothing in it is judged (its note is left
//   out of the run, its records kept). After that its listing is taken as it
//   is (an empty or `att/`-only folder then deletes nothing, by the existing
//   rules: an emptied remote folder never explains a deletion), so "arriving"
//   never waits for ever (iCloud's `cloudUnlistedTimeout`);
// - the remote's `vault.json` is needed to know it is the same vault: one
//   still arriving after the wait stops the run (`SyncError.notDownloaded`).
//
// When this device first saw each one is kept in the sync state
// (`SyncState.arriving`), so the bounds hold across runs and processes.

/// What a run knows about arriving files. Under the engine's `mutex`.
struct ArrivalTracker {
    /// Paths asked for this run (`requestDownload` once each).
    var requested = Set<[String]>()
    /// When the run's waiting ends (set by the first wait).
    var deadline: Date?
    /// State keys (`SyncState.arriving`) this run looked at: arriving, or settled.
    var seen = Set<String>()
}

extension SyncEngine {
    /// How many paths one `requestDownload` call asks for.
    static let arrivalWindow = 64

    /// The `SyncState.arriving` key of a remote path (a folder's ends with `/`).
    static func arrivalKey(_ path: [String], folder: Bool = false) -> String {
        path.joined(separator: "/") + (folder ? "/" : "")
    }

    /// True for a transport error that says a listed file's bytes are not here yet.
    static func isUnavailable(_ error: Error) -> Bool {
        (error as? any TransientRemoteError)?.isUnavailable == true
    }

    /// Asks the remote for `paths` not asked for yet this run, `arrivalWindow` at a time.
    /// Best effort: a refused request leaves the files to the wait and the next run.
    func request(_ paths: [[String]]) {
        guard !options.dryRun, !options.pushOnly else { return }
        let fresh = locked { () -> [[String]] in
            let new = paths.filter { !arrivals.requested.contains($0) }
            arrivals.requested.formUnion(new)
            return new
        }
        var start = 0
        while start < fresh.count {
            let window = Array(fresh[start..<min(start + Self.arrivalWindow, fresh.count)])
            try? transport.requestDownload(window)
            start += Self.arrivalWindow
        }
    }

    /// Whether the remote file at `path` (listed as `entry`) can be read now.
    /// One listed as not downloaded is asked for and waited for (within the
    /// run's `arrivalWait`); if it does not arrive it is reported as arriving
    /// and false is returned: the caller leaves it alone this run. No entry, or
    /// an available one: true.
    func available(_ path: [String], entry: RemoteEntry?) throws -> Bool {
        guard let entry, !entry.isCollection else { return true }
        switch entry.availability {
        case .available:
            settled(path)
            return true
        case .failed(let why):
            request([path])
            noteArriving(path, "the provider could not download it (\(SyncReport.printable(why))); kept, tried again later")
            return false
        case .remoteOnly, .downloading:
            break
        }
        // A dry run or a mirror reads nothing it would have to wait for.
        guard !options.dryRun, !options.pushOnly else {
            noteArriving(path)
            return false
        }
        request([path])
        if try waitForArrival(path) {
            settled(path)
            return true
        }
        noteArriving(path)
        return false
    }

    /// Polls `path` until it is available, gone, failed or the run's waiting is over.
    private func waitForArrival(_ path: [String]) throws -> Bool {
        let deadline = locked { () -> Date in
            if let d = arrivals.deadline { return d }
            let d = Date().addingTimeInterval(max(options.arrivalWait, 0))
            arrivals.deadline = d
            return d
        }
        var pause = 0.01
        while true {
            try checkCancelled()
            try locked { try budget.checkTime() }
            guard let now = try transport.stat(path) else { return true }   // gone: the read says so
            switch now.availability {
            case .available: return true
            case .failed: return false
            case .remoteOnly, .downloading: break
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return false }
            Thread.sleep(forTimeInterval: min(pause, left))
            pause = min(pause * 2, 0.25)
        }
    }

    /// Reports `path` as arriving (or, past `arrivalStall`, as an error) and
    /// records when this device first found it so.
    func noteArriving(_ path: [String], _ why: String = "not downloaded by the provider yet; asked for it, synced on a later run") {
        let key = Self.arrivalKey(path)
        locked {
            arrivals.seen.insert(key)
            let since = state.arriving?[key] ?? options.now
            if !options.dryRun, state.arriving?[key] == nil { state.arriving = (state.arriving ?? [:]).merging([key: since]) { a, _ in a } }
            let waited = options.now.timeIntervalSince(since)
            if waited >= options.arrivalStall {
                report.errors.append(.init(path: SyncReport.printable(key), message: "still not downloaded by the provider "
                    + "\(Int(waited / 60)) min after this device first asked for it; kept (never deleted), check that the provider is online"))
            } else {
                report.arriving.append(.init(path: SyncReport.printable(key), message: why))
            }
        }
    }

    /// `path` is readable: it is no longer arriving.
    private func settled(_ path: [String], folder: Bool = false) {
        let key = Self.arrivalKey(path, folder: folder)
        locked {
            guard state.arriving?[key] != nil else { return }
            if !options.dryRun { state.arriving?[key] = nil }
        }
    }

    /// Whether the folder at `path` (listed as `entry`) was listed before its
    /// files and is still within `unlistedTimeout` of when this device first
    /// found it so: then it is asked for and reported as arriving, and the
    /// caller judges nothing in it this run.
    func folderArriving(_ path: [String], entry: RemoteEntry) -> Bool {
        guard entry.isCollection else { return false }
        guard entry.availability != .available else {
            settled(path, folder: true)
            return false
        }
        request([path])
        // Asked for: a provider that has it at hand lists it now, before anything below is listed.
        if !options.dryRun, !options.pushOnly, let now = try? transport.stat(path), now.isCollection, now.availability == .available {
            settled(path, folder: true)
            return false
        }
        let key = Self.arrivalKey(path, folder: true)
        return locked {
            arrivals.seen.insert(key)
            let since = state.arriving?[key] ?? options.now
            if !options.dryRun, state.arriving?[key] == nil { state.arriving = (state.arriving ?? [:]).merging([key: since]) { a, _ in a } }
            let waited = options.now.timeIntervalSince(since)
            if waited < options.unlistedTimeout {
                report.arriving.append(.init(path: SyncReport.printable(key), message: "listed before its files; "
                    + "nothing in it is judged until they arrive (asked for them)"))
                return true
            }
            report.skipped.append(.init(path: SyncReport.printable(key), message: "listed without its files for "
                + "\(Int(waited)) s; taken as it is listed (nothing is deleted for it)"))
            return false
        }
    }

    /// Before anything is read at the root: every root file the provider has
    /// not downloaded is asked for at once, and `vault.json` waited for (the run
    /// cannot tell it is the same vault without it).
    func awaitRootFiles(_ remoteRoot: [String: RemoteEntry]) throws {
        let pending = remoteRoot.values.filter { !$0.isCollection && $0.availability != .available }.map { [$0.name] }
        guard !pending.isEmpty else { return }
        request(pending.sorted { $0[0] < $1[0] })
        if let manifest = remoteRoot[Vault.manifestName], !manifest.isCollection,
           try !available([Vault.manifestName], entry: manifest) {
            throw SyncError.notDownloaded(Vault.manifestName)
        }
    }

    /// After the notes are listed: asks for every file the run would download
    /// (the vault lacks it) that the provider has not downloaded, in windows,
    /// so they come in while the run works through the others.
    func requestArrivals(_ remoteNotes: [String: [RemoteEntry]]) {
        guard !options.dryRun, !options.pushOnly else { return }
        var wanted: [[String]] = []
        for id in remoteNotes.keys.sorted() {
            let entries = remoteNotes[id] ?? []
            let lazy = entries.filter { !$0.isCollection && $0.availability != .available }
            if !lazy.isEmpty, let local = localRevisionNames(id) {
                for e in lazy where !local.contains(e.name) { wanted.append([Vault.notesName, id, e.name]) }
            }
            if case .success(let att?)? = locked({ attListings[id] }) {
                let lazyBlobs = att.filter { !$0.isCollection && $0.availability != .available }
                if !lazyBlobs.isEmpty, let local = localBlobNames(id) {
                    for e in lazyBlobs where !local.contains(e.name) {
                        wanted.append([Vault.notesName, id, Vault.attachmentsName, e.name])
                    }
                }
            }
        }
        request(wanted)
    }

    /// Notes whose `att/` a provider listed before its files: left out of the
    /// run (their records kept) while they are arriving (`folderArriving`).
    func setAsideArrivingAttachments(_ notes: [String: [RemoteEntry]]) -> [String: [RemoteEntry]] {
        var out = notes
        for (id, entries) in notes.sorted(by: { $0.key < $1.key }) {
            guard let att = entries.first(where: { $0.name == Vault.attachmentsName && $0.isCollection }),
                  folderArriving([Vault.notesName, id, Vault.attachmentsName], entry: att) else { continue }
            out[id] = nil
            notesNotReadable.insert(id)
            attListings[id] = nil
        }
        return out
    }

    /// At the end of a run that looked at everything: forgets what is no
    /// longer arriving (or no longer listed).
    func finishArrivals() {
        guard !options.dryRun, notesListed, report.stoppedEarly == nil else { return }
        let seen = locked { arrivals.seen }
        state.arriving = state.arriving?.filter { seen.contains($0.key) }
        if state.arriving?.isEmpty == true { state.arriving = nil }
    }
}
