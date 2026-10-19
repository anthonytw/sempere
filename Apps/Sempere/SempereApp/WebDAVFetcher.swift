import Foundation
import Sempere
import SempereSync
import SempereWebDAV

/// Fills a partial WebDAV copy while it is open (docs/io.md "WebDAV vaults
/// in the app", "Partial copies"; format.md §1.2): note revisions in the
/// background, the ones the app asks for first, and attachment blobs on
/// demand (plus, with `fillsBlobs`, in the background once every note is in).
///
/// It is the WebDAV side of the iCloud machinery, not a second one: `hooks`
/// are `CloudVault.Hooks` that describe the copy's files from its markers
/// (an incomplete note's revisions are `missing`, a blob with a stand-in is
/// `missing`, a failed fetch is `failed`) and turn a download request into a
/// priority fetch, so `ProgressiveLoad`, `downloadNote`, `requireLocal`,
/// `CloudBlobs` and `downloadEverything` work on it unchanged.
///
/// Each fetch is one library run (`WebDAVLocalCopy.fetch`): it never
/// uploads, never deletes anything on the server, never writes a root file
/// and never touches a complete note, so it runs while the copy is edited
/// and pushed (runs take turns on the copy's sync state).
final class WebDAVFetcher: @unchecked Sendable {
    /// Runs one fetch of `scope`, checked under `vault` when it is unlocked
    /// (the model supplies it: remote, endpoint, copy).
    typealias Fetch = @Sendable (_ scope: WebDAVFetchScope, _ vault: Vault?) async throws -> SyncReport

    let copy: WebDAVLocalCopy
    /// The server's host, for the texts of the download machinery (`CloudSource`).
    let serverName: String
    private let fetch: Fetch
    private let lock = NSLock()
    /// Notes asked for, most recent first.
    private var wantedNotes: [UUID] = []
    /// Blobs asked for (`<note id>/<file name>`), oldest first.
    private var wantedBlobs: [String] = []
    /// Why the last fetch of a note or blob failed, by note id or blob key;
    /// cleared when it is asked for again.
    private var failures: [String: String] = [:]
    private var vault: Vault?
    private var fillsBlobs: Bool
    /// Notes a run left as they were without an error (still incomplete, or
    /// with blobs still pending), by note id: not fetched again until the
    /// time given, so such a note is never fetched in a loop and never holds
    /// the others back. The pause doubles with each such run, up to
    /// `maxParkDelay`. A new fetcher (reopening, "Download Again") starts afresh.
    private var parkedNotes: [String: (until: ContinuousClock.Instant, runs: Int)] = [:]
    /// The same for the background fill of attachments, by note id.
    private var parkedBlobNotes: [String: (until: ContinuousClock.Instant, runs: Int)] = [:]
    private let clock = ContinuousClock()
    private var running: Task<Void, Never>?
    private var wakeup: CheckedContinuation<Void, Never>?
    private var woken = false
    private var stopped = false
    /// Told (on the main actor) which notes changed after each run, and whether the copy is complete.
    private let changed: @MainActor @Sendable (WebDAVFetcher, Set<UUID>, Bool) -> Void

    /// `notes/` and a note's `att/` (format.md §1).
    static let notesFolder = "notes", attachmentsFolder = "att"

    /// A lowercase-UUID note folder name (format.md §1).
    static func isNoteFolderName(_ s: String) -> Bool { UUID(uuidString: s)?.uuidString.lowercased() == s }

    /// How many notes one background run fetches (a push waits at most one run for the sync state).
    static let batch = 12
    /// The pause after a run that failed as a whole (offline), doubling up to `maxRetryDelay`.
    var retryDelay = Duration.seconds(2)
    var maxRetryDelay = Duration.seconds(60)
    /// The longest pause of a parked note.
    var maxParkDelay = Duration.seconds(600)

    init(copy: WebDAVLocalCopy, serverName: String, fillsBlobs: Bool, fetch: @escaping Fetch,
         changed: @escaping @MainActor @Sendable (WebDAVFetcher, Set<UUID>, Bool) -> Void) {
        self.copy = copy
        self.rootPath = copy.folder.standardizedFileURL.resolvingSymlinksInPath().path
        self.serverName = serverName
        self.fillsBlobs = fillsBlobs
        self.fetch = fetch
        self.changed = changed
    }

    // MARK: - Lifecycle

    /// Starts the background loop (once).
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard running == nil, !stopped else { return }
        running = Task.detached(priority: .utility) { [weak self] in await self?.loop() }
    }

    /// Stops after the run in progress, which is returned: nothing may replace
    /// or remove the copy until it has ended.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        lock.lock()
        stopped = true
        let task = running
        let waiter = wakeup
        wakeup = nil
        lock.unlock()
        waiter?.resume()
        return task
    }

    /// The vault was unlocked: later fetches check each file under its key.
    func setVault(_ vault: Vault?) {
        lock.lock(); self.vault = vault; lock.unlock()
    }

    /// The "download attachments in the background" setting changed.
    func setFillsBlobs(_ on: Bool) {
        lock.lock(); fillsBlobs = on; lock.unlock()
        wake()
    }

    /// Asks for note `id` first (opened, selected, or listed by a pass).
    func want(note id: UUID) {
        lock.lock()
        failures[id.uuidString.lowercased()] = nil
        wantedNotes.removeAll { $0 == id }
        wantedNotes.insert(id, at: 0)
        if wantedNotes.count > 256 { wantedNotes.removeLast(wantedNotes.count - 256) }
        lock.unlock()
        wake()
    }

    /// Asks for the blob `fileName` of note `id` (a page shows it, a recording plays).
    func want(blob fileName: String, of id: UUID) {
        let key = "\(id.uuidString.lowercased())/\(fileName)"
        lock.lock()
        failures[key] = nil
        if !wantedBlobs.contains(key) { wantedBlobs.append(key) }
        lock.unlock()
        wake()
    }

    private func wake() {
        lock.lock()
        let waiter = wakeup
        wakeup = nil
        if waiter == nil { woken = true }
        lock.unlock()
        waiter?.resume()
    }

    /// Sleeps until `wake()`, `stop()` or `duration` (nil: no limit).
    private func sleep(_ duration: Duration?) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if woken || stopped {
                woken = false
                lock.unlock()
                c.resume()
                return
            }
            wakeup = c
            lock.unlock()
            guard let duration else { return }
            Task.detached { [weak self] in
                try? await Task.sleep(for: duration)
                self?.wake()
            }
        }
    }

    // MARK: - The loop

    /// What the next run fetches; nil when nothing is to be fetched now. Parked
    /// notes are left out; `wake` is then when the first of them may run again.
    private func nextScope() -> (scope: WebDAVFetchScope?, wake: Duration?) {
        let now = clock.now
        lock.lock()
        let blobs = wantedBlobs
        let notes = wantedNotes
        let fills = fillsBlobs
        parkedNotes = parkedNotes.filter { $0.value.until > now }
        parkedBlobNotes = parkedBlobNotes.filter { $0.value.until > now }
        let parked = Set(parkedNotes.keys), parkedBlobs = Set(parkedBlobNotes.keys)
        let wake = (Array(parkedNotes.values) + Array(parkedBlobNotes.values)).map(\.until).min().map { $0 - now }
        lock.unlock()
        let root = copy.folder
        if !blobs.isEmpty {
            // Blobs asked for, with their notes' revisions if those are still missing.
            let ids = Array(Set(blobs.compactMap { UUID(uuidString: String($0.prefix(36))) }))
            return (WebDAVFetchScope(notes: ids, revisions: true, blobs: .only(Set(blobs)), maxNotes: ids.count), nil)
        }
        let incomplete = Set(WebDAVPartialCopy.incompleteNotes(root)).subtracting(parked)
        let asked = notes.filter { incomplete.contains($0.uuidString.lowercased()) }
        if !asked.isEmpty {
            return (WebDAVFetchScope(notes: Array(asked.prefix(WebDAVFetchScope.defaultConcurrency)), blobs: .none,
                                     maxNotes: WebDAVFetchScope.defaultConcurrency), nil)
        }
        if !incomplete.isEmpty {
            // Failed notes go last, so they cannot hold the rest back; they are still retried.
            lock.lock()
            let failed = Set(failures.keys)
            lock.unlock()
            let order = incomplete.sorted().filter { !failed.contains($0) } + incomplete.sorted().filter { failed.contains($0) }
            return (WebDAVFetchScope(notes: order.prefix(Self.batch).compactMap(UUID.init(uuidString:)), blobs: .none,
                                     maxNotes: Self.batch), nil)
        }
        if fills {
            let ids = WebDAVPartialCopy.pendingBlobsByNote(root).keys.filter { !parkedBlobs.contains($0) && !parked.contains($0) }
                .sorted().prefix(WebDAVFetchScope.defaultConcurrency).compactMap(UUID.init(uuidString:))
            if !ids.isEmpty {
                return (WebDAVFetchScope(notes: ids, revisions: false, blobs: .all, maxNotes: ids.count), nil)
            }
        }
        return (nil, wake)
    }

    private func loop() async {
        var delay = retryDelay
        while !isStopped {
            let next = nextScope()
            guard let scope = next.scope else {
                if !copy.isPartial { await notify([], complete: true); return }
                // Until something is asked for, the setting changes or a parked note may run again.
                await sleep(next.wake)
                continue
            }
            let vault = currentVault
            let result: Result<SyncReport, any Error>
            do { result = .success(try await fetch(scope, vault)) } catch { result = .failure(error) }
            if isStopped { return }
            switch result {
            case .success(let report):
                let touched = record(report, scope: scope)
                await notify(touched, complete: !copy.isPartial)
                if report.errors.isEmpty && report.quarantined.isEmpty {
                    delay = retryDelay
                } else {
                    // Something failed: wait before trying it again (failed notes go last meanwhile).
                    await sleep(delay)
                    delay = min(delay * 2, maxRetryDelay)
                }
            case .failure(let error):
                // The whole run failed (offline, wrong password): every note asked for reports it.
                fail(scope, WebDAVErrorText.message(error))
                await notify(Set(scope.notes ?? []), complete: false)
                await sleep(delay)
                delay = min(delay * 2, maxRetryDelay)
            }
        }
    }

    /// Every note and blob a run that failed as a whole asked for reports `reason`.
    private func fail(_ scope: WebDAVFetchScope, _ reason: String) {
        lock.lock(); defer { lock.unlock() }
        for id in scope.notes ?? [] { failures[id.uuidString.lowercased()] = reason }
        if case .only(let keys) = scope.blobs { for k in keys { failures[k] = reason } }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private var currentVault: Vault? { lock.lock(); defer { lock.unlock() }; return vault }

    /// Takes in a run's report: what was asked for and is done is no longer
    /// asked for; what failed is remembered (`hooks` reports it). Returns the
    /// notes the run looked at.
    private func record(_ report: SyncReport, scope: WebDAVFetchScope) -> Set<UUID> {
        let root = copy.folder
        let incomplete = Set(WebDAVPartialCopy.incompleteNotes(root))
        let pendingBlobs = WebDAVPartialCopy.pendingBlobsByNote(root)
        var failed: [String: String] = [:]
        for e in report.errors + report.quarantined {
            // `notes/<id>/…`: the note (or the blob, for `att/`) it concerns.
            let parts = e.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0] == Self.notesFolder else { continue }
            if parts.count == 4, parts[2] == Self.attachmentsFolder { failed["\(parts[1])/\(parts[3])"] = e.message }
            failed[parts[1]] = failed[parts[1]] ?? e.message
        }
        lock.lock()
        for (k, v) in failed { failures[k] = v }
        wantedNotes.removeAll { !incomplete.contains($0.uuidString.lowercased()) }
        wantedBlobs.removeAll { key in
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return true }
            // Done, gone from the server, or failed (asked for again by whoever waits for it).
            return !(pendingBlobs[parts[0]] ?? []).contains(parts[1]) || failed[key] != nil
                || (failed[parts[0]] != nil && incomplete.contains(parts[0]))
        }
        for id in scope.notes ?? [] where !incomplete.contains(id.uuidString.lowercased()) {
            failures[id.uuidString.lowercased()] = nil
        }
        // A note the run left as it was is parked (with or without an error): fetching it again at
        // once would only repeat the run, and it must not hold the others back.
        let now = clock.now
        func park(_ table: inout [String: (until: ContinuousClock.Instant, runs: Int)], _ id: String) {
            let runs = (table[id]?.runs ?? 0) + 1
            let pause = min(retryDelay * (1 << min(runs - 1, 16)), maxParkDelay)
            table[id] = (now + pause, runs)
        }
        for id in (scope.notes ?? []).map({ $0.uuidString.lowercased() }) {
            switch scope.blobs {
            case .none:
                if incomplete.contains(id) { park(&parkedNotes, id) } else { parkedNotes[id] = nil }
            case .all:
                if pendingBlobs[id] != nil { park(&parkedBlobNotes, id) } else { parkedBlobNotes[id] = nil }
            case .only:
                if scope.revisions, incomplete.contains(id) { park(&parkedNotes, id) }
            }
        }
        if case .only = scope.blobs {
            // A blob asked for and still pending after its run is not asked for again by itself: whoever
            // waits for it asks again (or reports the failure), so it never runs in a loop.
            wantedBlobs.removeAll { key in
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                return parts.count == 2 && (pendingBlobs[parts[0]] ?? []).contains(parts[1])
            }
        }
        lock.unlock()
        return Set(scope.notes ?? [])
    }

    private func notify(_ notes: Set<UUID>, complete: Bool) async {
        await changed(self, notes, complete)
    }

    // MARK: - State for the iCloud machinery

    /// Those of `ids` whose notes are marked incomplete (one file check each).
    func incomplete(among ids: [UUID]) -> Set<UUID> {
        let notes = copy.folder.appendingPathComponent(Self.notesFolder)
        return Set(ids.filter { PartialCopy.isIncomplete(noteFolder: notes.appendingPathComponent($0.uuidString.lowercased())) })
    }

    /// The failure of note `id`'s last fetch, if any.
    func failure(note id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return failures[id]
    }

    /// The failure of the blob `key` (`<note id>/<file name>`), or of its note.
    func failure(blob key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return failures[key] ?? failures[String(key.prefix(36))]
    }

    /// `CloudVault.Hooks` over the copy (see the type's comment).
    var hooks: CloudVault.Hooks {
        let root = rootPath
        return CloudVault.Hooks(
            isUbiquitous: { url in
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                return path == root || path.hasPrefix(root + "/")
            },
            state: { [weak self] item in self?.state(of: item.url) ?? .current },
            request: { [weak self] item in self?.request(item.url) },
            source: .server(serverName))
    }

    /// Where a file of the copy is in the partial copy's terms.
    enum Place: Equatable {
        /// A note folder (asked for when it lists no revision yet).
        case note(UUID)
        /// A revision file of a note.
        case revision(UUID)
        /// A blob of a note, by file name.
        case blob(UUID, String)
        /// Anything else (root files, keys, the inbox).
        case other
    }

    /// The place of `url` in the copy at `root` (a path).
    static func place(of url: URL, root: String) -> Place {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { return .other }
        let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == Self.notesFolder, Self.isNoteFolderName(parts[1]),
              let id = UUID(uuidString: parts[1]) else { return .other }
        switch parts.count {
        case 2: return .note(id)
        case 3: return parts[2] == Self.attachmentsFolder ? .other : .revision(id)
        case 4 where parts[2] == Self.attachmentsFolder: return .blob(id, parts[3])
        default: return .other
        }
    }

    /// The copy's folder, resolved once (every state query compares paths with it).
    private let rootPath: String

    func state(of url: URL) -> CloudItemState {
        let fm = FileManager.default
        let noteFolder = { (id: UUID) in self.copy.folder.appendingPathComponent(Self.notesFolder)
            .appendingPathComponent(id.uuidString.lowercased()) }
        switch Self.place(of: url, root: rootPath) {
        case .note(let id), .revision(let id):
            // Every revision of an incomplete note counts as missing, even those already here:
            // the note is read only once all of them are (format.md §1.2).
            guard PartialCopy.isIncomplete(noteFolder: noteFolder(id)) else {
                return fm.fileExists(atPath: url.path) ? .current : .gone
            }
            return failure(note: id.uuidString.lowercased()).map { .failed($0) } ?? .missing
        case .blob(let id, let name):
            if fm.fileExists(atPath: url.path) { return .current }
            let att = noteFolder(id).appendingPathComponent(Self.attachmentsFolder)
            let pending = fm.fileExists(atPath: att.appendingPathComponent(PartialCopy.standInName(for: name)).path)
                || PartialCopy.isIncomplete(noteFolder: noteFolder(id))
            guard pending else { return .gone }
            return failure(blob: "\(id.uuidString.lowercased())/\(name)").map { .failed($0) } ?? .missing
        case .other:
            return fm.fileExists(atPath: url.path) ? .current : .gone
        }
    }

    func request(_ url: URL) {
        switch Self.place(of: url, root: rootPath) {
        case .note(let id), .revision(let id): want(note: id)
        case .blob(let id, let name): want(blob: name, of: id)
        case .other: break
        }
    }
}
