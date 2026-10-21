import Foundation
import Observation
import Sempere
import SempereSync
import SempereWebDAV

/// How a run of a `SyncSession` goes.
enum SyncRunMode: Sendable, Equatable {
    /// Two-way (the vault is open and unlocked here): takes what other devices wrote, merges settings,
    /// follows deletions the rules explain.
    case twoWay
    /// The vault is closed or locked: only uploads what this device has (quick captures recorded into a
    /// closed vault, edits a run before the lock missed), never writes the local copy and never takes the
    /// remote's `vault.json` or journal (`SyncOptions.pushOnly` + `keepServerChanges`). What other
    /// devices wrote arrives at the next unlocked run.
    case uploadOnly
}

/// One run a `SyncSession` asks for: its mode, and the bounds a background task gives it.
struct SyncRunRequest: Sendable {
    var mode: SyncRunMode
    /// The run's time bound (`SyncLimits.maxDuration`); nil: the default. A background task shares its
    /// time out this way (`SyncCoordinator.runBackgroundRefresh`, design §4.2).
    var maxDuration: TimeInterval?
    /// An upload-only run also stages what the target holds that this copy lacks (`LockedStaging`, P8b), for
    /// the next unlock to place. Off between `SyncSession.stageInterval`s outside background tasks.
    var stage = false
    /// Stop the run between files when any is set (`SyncOptions.isCancelled`): iOS took a background task's
    /// time back (the task's own flag, and the coordinator's app-wide one, which reaches every run going).
    var cancels: [SyncRunCancel] = []

    /// Applies the bounds to a run's options.
    func apply(to options: inout SyncOptions) {
        if let maxDuration { options.limits.maxDuration = maxDuration }
        let cancels = self.cancels
        if !cancels.isEmpty { options.isCancelled = { cancels.contains { $0.isSet } } }
    }
}

/// A cancellation flag a run polls between files (a background task's expiry sets it).
final class SyncRunCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
    func cancel() { lock.lock(); set = true; lock.unlock() }
}

/// One (vault, target) pair's sync (docs/design/device-first-sync.md §4, docs/io.md "Sync targets in the
/// app"): when to run (`SyncSchedule`), one run at a time, and its status (`SyncStatus`). The app's
/// `SyncCoordinator` owns one per in-app vault with a target, open or not; the open vault's session runs
/// two-way while the vault is unlocked and hands what each run changed locally to the model
/// (`onChanges`, arrivals into reconcile and RemoteMerge).
@MainActor
@Observable
final class SyncSession {
    /// The target's id (a `SyncTarget`, which a WebDAV location also is).
    let locationID: UUID
    /// The vault (its `vaultId`), when known.
    let vaultID: UUID?
    /// The vault's name, for the bar.
    let name: String
    /// The target's kind: the bar's wording (a folder or a server).
    var kind = SyncTargetKind.webdav
    /// The target's name (the folder's or the host), for the target list.
    var targetName = ""
    /// When the target was added (the order of a vault's sessions).
    var added = Date.distantPast
    /// When runs happen; the session tells it about writes, demands and runs. Tests shorten its delays.
    var schedule = SyncSchedule()
    /// A run is going.
    private(set) var isSyncing = false
    /// What the last run (or the failure that stopped it) reported; empty: all is well.
    private(set) var problems: [WebDAVSyncProblem] = []
    /// The last run's error message, when it threw.
    private(set) var failure: String?
    /// Files of the local copy the target has not confirmed (recounted after each run and write).
    private(set) var unconfirmed = 0
    /// When a run last finished without problems.
    private(set) var lastSuccess: Date?
    /// Runs are two-way: the vault is open and unlocked here.
    private(set) var twoWay = false
    /// What the last run did, for "Show Details" and tests.
    private(set) var lastReport: SyncReport?
    /// Files the last runs left arriving on the target (a provider still delivering them).
    private(set) var arriving = 0
    /// Files other devices wrote that are staged for this vault's next unlock (`LockedStaging`, P8b).
    private(set) var staged = 0
    /// When an upload-only run last staged downloads; staging runs at most every `stageInterval` outside
    /// background tasks (each stages, design §4.1).
    @ObservationIgnored private var lastStaged: Date?
    @ObservationIgnored var stageInterval: TimeInterval = 15 * 60
    /// Counts the staged files off the main actor (the model sets it; nil: no staging).
    @ObservationIgnored var countStaged: (@Sendable () async -> Int)?
    /// The last run could not read the target's password: the device is locked and was not unlocked since it
    /// started. Not a problem and no backoff: the run waits for the unlock (review of #74, B1).
    private(set) var waitingForDeviceUnlock = false

    /// Runs one sync off the main actor and returns its report (the coordinator supplies it: endpoint,
    /// copy, vault, options).
    @ObservationIgnored let run: @Sendable (SyncRunRequest) async throws -> SyncReport
    /// Counts the copy's unconfirmed files off the main actor.
    @ObservationIgnored let countUnconfirmed: @Sendable () async -> Int
    /// Told when a run ends without problems (the coordinator stores the date).
    @ObservationIgnored var onSuccess: (Date) -> Void = { _ in }
    /// Told what a two-way run changed in the local copy (the open vault's model applies it).
    @ObservationIgnored var onChanges: (LocalChanges) -> Void = { _ in }
    /// Called after every two-way run, whether it returned or threw (the model compares its open vault
    /// with the disk: a run that stopped may still have taken a new `vault.json`).
    @ObservationIgnored var afterTwoWayRun: () -> Void = {}
    /// Taken around each run: the coordinator's budget (at most a few runs at once app-wide).
    @ObservationIgnored var admit: @MainActor (_ priority: @escaping @MainActor () -> Bool) async -> Void = { _ in }
    @ObservationIgnored var release: @MainActor () -> Void = {}
    /// The open vault's session (the coordinator sets it): its runs take the slot kept for it.
    @ObservationIgnored var isOpenVault = false
    /// The coordinator's app-wide cancel flag, read when a run starts (`SyncCoordinator.cancelAllRuns`).
    @ObservationIgnored var appCancel: @MainActor () -> SyncRunCancel? = { nil }
    /// Runs automatically at all (the coordinator's background sessions; the open vault's always do).
    @ObservationIgnored var runsAutomatically = true
    /// The periodic pace is paused (a closed vault while the app is in the background): only a write
    /// (a voice note delivered into it) or a demand starts a run (review of #72).
    @ObservationIgnored var periodicPaused = false
    @ObservationIgnored var now: () -> Date = { Date() }
    /// How often the loop looks at the schedule.
    @ObservationIgnored var tick = Duration.seconds(1)
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var running: Task<SyncReport?, Never>?
    /// The run going now, if any (the copy must not be replaced or removed until it has ended).
    var currentRun: Task<SyncReport?, Never>? { running }

    init(locationID: UUID, vaultID: UUID?, name: String, lastSuccess: Date?,
         run: @escaping @Sendable (SyncRunRequest) async throws -> SyncReport,
         countUnconfirmed: @escaping @Sendable () async -> Int) {
        self.locationID = locationID
        self.vaultID = vaultID
        self.name = name
        self.lastSuccess = lastSuccess
        self.run = run
        self.countUnconfirmed = countUnconfirmed
    }

    // MARK: - Lifecycle

    /// Starts the loop (upload-only until `vaultUnlocked`).
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.runsAutomatically, self.schedule.isDue(now: self.now()),
                   !self.periodicPaused || self.schedule.pendingWrite != nil || self.schedule.demanded {
                    _ = await self.runOnce()
                }
                try? await Task.sleep(for: self.tick)
            }
        }
        Task { await recount() }
    }

    /// Stops the loop; a run in progress finishes. Returns that run: nothing else may sync or replace
    /// the copy until it has ended (both use the copy's one sync-state file).
    @discardableResult
    func stop() -> Task<SyncReport?, Never>? {
        loop?.cancel()
        loop = nil
        twoWay = false
        return running
    }

    /// The vault was unlocked here: runs are two-way from now on, and one runs now.
    func vaultUnlocked() {
        twoWay = true
        schedule.demand()
    }

    /// The vault closed or locked here: runs only upload until it is unlocked again.
    func vaultClosed() {
        twoWay = false
    }

    // MARK: - Events

    /// A delta, blob, capture or setting was written to the copy.
    func noteWrite() {
        schedule.noteWrite(at: now())
        unconfirmed += 1
    }

    /// Run as soon as possible (the app became active, the network came back).
    func demand() { schedule.demand() }

    /// "Sync Now": runs (after the run going, if any) and returns its report; nil when it threw
    /// (`failure` says why).
    @discardableResult
    func syncNow() async -> SyncReport? {
        // A run in flight may predate the change asked for: wait for it, then run anew.
        while let running { _ = await running.value }
        return await runOnce()
    }

    /// One run for a background task (`SyncCoordinator`): bounded by `maxDuration`, stopped between files when
    /// `cancel` is set. A session whose run is already going is skipped, never waited for: that run may be a
    /// foreground one without a bound (review of #74, B2; the task's expiry stops it through the app-wide flag).
    /// Returns whether the run ended without problems, and whether it changed anything.
    func runInBackground(maxDuration: TimeInterval?, cancel: SyncRunCancel?) async -> (ok: Bool, changed: Bool) {
        guard running == nil else { return (false, false) }
        let report = await runOnce(maxDuration: maxDuration, cancel: cancel)
        guard let report else { return (false, false) }
        let changed = !report.uploaded.isEmpty || !report.downloaded.isEmpty || !report.deleted.isEmpty
            || !report.arriving.isEmpty || !report.merged.isEmpty
        return (problems.isEmpty, changed)
    }

    /// The network came back: a run soon, without waiting out the backoff of earlier failures.
    func networkReturned() {
        schedule.resetBackoff()
        schedule.demand()
    }

    // MARK: - Runs

    private func runOnce(maxDuration: TimeInterval? = nil, cancel: SyncRunCancel? = nil) async -> SyncReport? {
        if let running { return await running.value }
        let mode: SyncRunMode = twoWay ? .twoWay : .uploadOnly
        var request = SyncRunRequest(mode: mode, maxDuration: maxDuration, cancels: [cancel, appCancel()].compactMap { $0 })
        if mode == .uploadOnly, countStaged != nil {
            let due = lastStaged.map { now().timeIntervalSince($0) >= stageInterval } ?? true
            request.stage = maxDuration != nil || cancel != nil || due
            if request.stage { lastStaged = now() }
        }
        let task = Task { () -> SyncReport? in
            await admit { [weak self] in mode == .twoWay || self?.isOpenVault == true }
            defer { release() }
            isSyncing = true
            schedule.started(at: now())
            defer {
                if mode == .twoWay { afterTwoWayRun() }
                isSyncing = false
                running = nil   // cleared by the run itself, so a waiter never takes a finished run for a current one
            }
            do {
                let report = try await run(request)
                lastReport = report
                // An upload-only run keeps a device list another device changed (`keepServerChanges`):
                // it arrives at the next unlocked run, so it is no problem then.
                let found = WebDAVSyncProblem.from(report: report).filter { mode == .twoWay || $0 != .serverChangedManifest }
                problems = found
                failure = nil
                waitingForDeviceUnlock = false
                arriving = report.arriving.count
                let ok = found.isEmpty
                let changed = !report.uploaded.isEmpty || !report.downloaded.isEmpty || !report.deleted.isEmpty
                    || !report.arriving.isEmpty || !report.merged.isEmpty
                schedule.finished(at: now(), success: ok, changed: changed)
                if ok {
                    lastSuccess = now()
                    onSuccess(lastSuccess ?? now())
                }
                if mode == .twoWay, let changes = report.changed, !changes.isEmpty { onChanges(changes) }
                await recount()
                return report
            } catch is CancellationError {
                schedule.finished(at: now(), success: false)
                return nil
            } catch WebDAVPasswordError.locked {
                // Waiting for the device's first unlock: no problem shown, no backoff (the app becoming active
                // asks every session for a run).
                waitingForDeviceUnlock = true
                problems = []
                failure = nil
                schedule.finished(at: now(), success: true)
                return nil
            } catch {
                waitingForDeviceUnlock = false
                problems = [SyncStatus.problem(from: error)]
                failure = WebDAVErrorText.message(error)
                schedule.finished(at: now(), success: false)
                await recount()
                return nil
            }
        }
        running = task
        return await task.value
    }

    private func recount() async {
        unconfirmed = await countUnconfirmed()
        if let countStaged { staged = await countStaged() }
    }

    // MARK: - Status

    /// The status model (docs/design/device-first-sync.md §8.3).
    var status: SyncStatus {
        SyncStatus(syncing: isSyncing, problems: problems, unconfirmed: unconfirmed, arriving: arriving,
                   twoWay: twoWay, lastSuccess: lastSuccess, folder: kind == .folder, deviceLocked: waitingForDeviceUnlock,
                   staged: staged)
    }

    /// True when the bar has something to say beyond "synced".
    var needsAttention: Bool { status.needsAttention }

    /// The bar's line.
    var headline: String { status.headline }

    /// What to do about a problem.
    static func text(for problem: WebDAVSyncProblem) -> String { SyncStatus.text(for: problem) }
}

/// What the note list's bar and the library say about one (vault, target) pair (docs/design/
/// device-first-sync.md §8.3): synced, syncing, offline, waiting for the unlock, or a problem. Pure
/// (the session's state in, text out), so it is tested without a run.
struct SyncStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case syncing
        /// The target cannot be reached; changes stay on this device. Not an error.
        case offline
        /// Changes made here that the target has not confirmed yet.
        case pending(Int)
        /// The vault is closed or locked here: what other devices changed arrives at the next unlock.
        case waitingForUnlock
        case problem(WebDAVSyncProblem)
        case synced
    }

    var syncing: Bool
    var problems: [WebDAVSyncProblem]
    var unconfirmed: Int
    var arriving: Int
    var twoWay: Bool
    var lastSuccess: Date?
    /// The target is a folder (iCloud Drive, any folder), not a server: the wording says so.
    var folder = false
    /// The last run waited for the device's first unlock (its password could not be read yet).
    var deviceLocked = false
    /// Files from other devices staged for the next unlock (`LockedStaging`).
    var staged = 0

    /// The problem for a run that threw: a folder target's own failures first (a folder that went away
    /// is "not found", one that cannot be reached now is "offline"), then a server's.
    static func problem(from error: Error) -> WebDAVSyncProblem {
        switch error {
        case FolderTargetError.missing: return .notFound
        case FolderTargetError.unavailable: return .offline
        case let e as FolderRemoteError where e.isTransient: return .offline
        default: return WebDAVSyncProblem.from(error: error)
        }
    }

    var kind: Kind {
        if syncing { return .syncing }
        if deviceLocked { return .waitingForUnlock }
        if problems.contains(.offline) { return .offline }
        if let problem = problems.first { return .problem(problem) }
        if unconfirmed > 0 { return .pending(unconfirmed) }
        if !twoWay { return .waitingForUnlock }
        return .synced
    }

    /// True when the user should look at it (offline and waiting are not problems).
    var needsAttention: Bool {
        if case .problem = kind { return true }
        return false
    }

    var headline: String {
        switch kind {
        case .syncing:
            return folder ? String(localized: "Syncing with the folder…") : String(localized: "Syncing with the server…")
        case .offline:
            if folder {
                return String(localized: "The folder cannot be reached now. Changes are kept on this device and sync when it is back.")
            }
            return unconfirmed > 0
                ? String(localized: "Offline. \(unconfirmed) changes are kept on this device and sync when the server can be reached.",
                         comment: "Sync status; the number is a count of files")
                : String(localized: "Offline. Changes are kept on this device and sync when the server can be reached.")
        case .pending(let n):
            return String(localized: "\(n) changes not synced yet", comment: "Sync status; the number is a count of files")
        case .waitingForUnlock:
            if staged > 0 {
                return String(localized: "\(staged) files from other devices are on this device and arrive when the vault is unlocked",
                              comment: "Sync status; the number is a count of files")
            }
            return String(localized: "Changes from other devices arrive when the vault is unlocked")
        case .problem(let p):
            if folder, p == .notFound {
                return String(localized: "The folder is gone or can no longer be opened. Nothing was synced. Choose it again, or remove it from Sync Targets.")
            }
            if folder, p == .offline {
                return String(localized: "The folder cannot be reached now. Changes are kept on this device and sync when it is back.")
            }
            return Self.text(for: p)
        case .synced:
            return arriving > 0
                ? String(localized: "Synced. \(arriving) files are still on their way.", comment: "Sync status; a count of files")
                : (folder ? String(localized: "Synced with the folder") : String(localized: "Synced with the server"))
        }
    }

    /// What to do about a problem.
    static func text(for problem: WebDAVSyncProblem) -> String {
        switch problem {
        case .offline:
            return String(localized: "Offline. Changes are kept on this device and sync when the server can be reached.")
        case .unauthorized:
            return String(localized: "The server refused the user name or password. Update the password.")
        case .certificate:
            return String(localized: "The server's certificate is not trusted or changed. Check the server, then trust its certificate again.")
        case .otherVault:
            return String(localized: "The server folder now holds another vault. Nothing was synced.")
        case .notFound:
            return String(localized: "The server folder is gone. Nothing was synced.")
        case .redirect(let target):
            return String(localized: "The server redirects to \(target). Connect to that address instead.",
                          comment: "The value is a URL")
        case .serverChangedManifest:
            return String(localized: "The vault's device list was changed both on this device and on the server. Both copies were kept; notes still sync.")
        case .failures(let lines):
            return String(localized: "Some files could not be synced: \(lines.joined(separator: "; "))",
                          comment: "The value lists file paths and errors (English)")
        case .failed(let message):
            return String(localized: "Sync failed: \(message)", comment: "The value is an error message (English)")
        }
    }
}
