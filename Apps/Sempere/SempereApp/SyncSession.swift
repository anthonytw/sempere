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
    /// The user asked for this run (Sync Now): a folder target's bookmark may mount its share then
    /// (`FolderTargetAccess.open`); scheduled runs never do.
    var interactive = false
    /// When the device's network path last became satisfied (the path monitor): a provider's late file is not
    /// counted as stalled before it (`SyncOptions.networkReturned`, offline audit P5).
    var networkReturned: Date?
    /// Attachment blobs too large for this target's recent windows (`SyncOptions.largeBlobs`, offline audit P3):
    /// `.now` for a background processing task and for Sync Now (time to send them), else `.auto`.
    var largeBlobs = LargeBlobPolicy.auto

    /// Applies the bounds to a run's options.
    func apply(to options: inout SyncOptions) {
        if let maxDuration { options.limits.maxDuration = maxDuration }
        options.largeBlobs = largeBlobs
        if let networkReturned { options.networkReturned = networkReturned }
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
    /// The last run moved files and was cut short (a run bound, the background time): the next one continues.
    private(set) var continuing = false
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
    /// Files the runs wrote into a provider's folder that it has not uploaded yet (`ProviderUploads`, offline audit
    /// P15): until they are, the target is not "synced", only written to.
    private(set) var providerPending = 0
    /// The provider reported an upload error for them (a full iCloud storage): the bar says so, as a problem.
    private(set) var providerError: String?
    /// Reads them off the main actor (folder targets; nil: none).
    @ObservationIgnored var providerSummary: (@Sendable () async -> ProviderUploads.Summary)?
    /// The folder is in iCloud Drive (the wording names it).
    @ObservationIgnored var uploadsViaICloud = false
    /// A folder target's path as run errors may spell it (as stored, symbolic links resolved): a write refused there
    /// is the target's (`WebDAVSyncProblem.notWritable`), not the device's own copy's (review of #124, note 5).
    @ObservationIgnored var targetRoots: [String] = []
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
    /// The target as the sync engine's remote, with what to call when done with it (a folder's security scope): for
    /// a re-encryption's claim and confirmation (key-hierarchy KH6). Nil: none (a kind of a later version).
    /// The target as the engine's remote, for a re-encryption: `close` ends its access, `syncedBefore` says this device
    /// synced with it (a claim never makes its base again then; `FolderTargetRun.syncedBefore`).
    @ObservationIgnored var openRemote: (@Sendable () async throws -> (remote: any SyncRemote, close: @Sendable () -> Void,
                                                                      syncedBefore: Bool))?
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
    @ObservationIgnored var runsAutomatically = true { didSet { wake() } }
    /// The periodic pace is paused (a closed vault while the app is in the background): only a write
    /// (a voice note delivered into it) or a demand starts a run (review of #72).
    @ObservationIgnored var periodicPaused = false { didSet { wake() } }
    /// The device has no network path now (`NWPathMonitor`, through the coordinator): a WebDAV target's scheduled
    /// runs wait and its bar says offline (offline audit P11). Folder targets need no network and ignore it; Sync
    /// Now still runs.
    private(set) var networkDown = false
    /// When the network path last came back (`networkReturned`, `networkChanged`); nil before it ever went away.
    private(set) var networkReturnedAt: Date?
    @ObservationIgnored var now: () -> Date = { Date() }
    /// The shortest sleep of the loop: it sleeps until the schedule's next run (offline audit P11: no tick every
    /// second while nothing is due), at least this long, and is woken by writes, demands and changes of state.
    @ObservationIgnored var tick = Duration.seconds(1)
    /// The longest sleep: the loop looks at the schedule at least this often, whatever it was told (nil: 60 ticks,
    /// a minute in the app).
    @ObservationIgnored var maxSleep: Duration?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The loop's sleep going now; cancelling it wakes the loop (`wake`).
    @ObservationIgnored private var sleeper: Task<Void, Never>?
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
                if self.mayRunNow, self.schedule.isDue(now: self.now()) {
                    _ = await self.runOnce(interactive: self.mayMount(demanded: self.schedule.demanded))
                }
                guard !Task.isCancelled else { return }
                let nap = Task { [delay = self.sleepDuration()] in _ = try? await Task.sleep(for: delay) }
                self.sleeper = nap
                await nap.value
                if self.sleeper == nap { self.sleeper = nil }
            }
        }
        Task { await recount() }
    }

    /// A scheduled run may start now: runs are automatic, the pace is not paused (or a write or demand waits), and
    /// a WebDAV target has a network path.
    private var mayRunNow: Bool {
        guard runsAutomatically, !(networkDown && kind == .webdav) else { return false }
        return !periodicPaused || schedule.pendingWrite != nil || schedule.demanded
    }

    /// How long the loop sleeps: until the schedule's next run, between `tick` and `maxSleep`; `maxSleep` while
    /// nothing may run (a wake ends it sooner).
    func sleepDuration() -> Duration {
        let floor = tick, ceiling = max(maxSleep ?? tick * 60, tick)
        guard mayRunNow, let next = schedule.nextRun(now: now()) else { return ceiling }
        let wait = Duration.milliseconds(Int64(max(0, next.timeIntervalSince(now())) * 1000))
        return min(max(wait, floor), ceiling)
    }

    /// A demanded run (the unlock, the app becoming active, the network back) may mount a folder target's share, at
    /// most every `mountInterval`; scheduled runs never do (review of #91, S4). Sync Now always may.
    private func mayMount(demanded: Bool) -> Bool {
        guard demanded, kind == .folder else { return false }
        if let last = lastMount, now().timeIntervalSince(last) < mountInterval { return false }
        lastMount = now()
        return true
    }
    @ObservationIgnored private var lastMount: Date?
    @ObservationIgnored var mountInterval: TimeInterval = 5 * 60

    /// Ends the loop's sleep now: something changed what is due.
    private func wake() {
        sleeper?.cancel()
    }

    /// Stops the loop; a run in progress finishes. Returns that run: nothing else may sync or replace
    /// the copy until it has ended (both use the copy's one sync-state file).
    @discardableResult
    func stop() -> Task<SyncReport?, Never>? {
        loop?.cancel()
        loop = nil
        wake()
        twoWay = false
        return running
    }

    /// The vault was unlocked here: runs are two-way from now on, and one runs now.
    func vaultUnlocked() {
        twoWay = true
        schedule.demand()
        wake()
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
        wake()
    }

    /// Run as soon as possible (the app became active, the network came back).
    func demand() {
        schedule.demand()
        wake()
    }

    /// "Sync Now": runs (after the run going, if any) and returns its report; nil when it threw
    /// (`failure` says why).
    @discardableResult
    func syncNow() async -> SyncReport? {
        // A run in flight may predate the change asked for: wait for it, then run anew.
        while let running { _ = await running.value }
        return await runOnce(interactive: true)
    }

    /// One run for a background task (`SyncCoordinator`): bounded by `maxDuration`, stopped between files when
    /// `cancel` is set. A session whose run is already going is skipped, never waited for: that run may be a
    /// foreground one without a bound (review of #74, B2; the task's expiry stops it through the app-wide flag).
    /// Returns whether the run ended without problems, and whether it changed anything.
    /// `full`: a background processing task's run, which also sends the large blobs short runs leave (offline audit P3).
    func runInBackground(maxDuration: TimeInterval?, cancel: SyncRunCancel?, full: Bool = false) async -> (ok: Bool, changed: Bool) {
        guard running == nil else { return (false, false) }
        let report = await runOnce(maxDuration: maxDuration, cancel: cancel, full: full)
        guard let report else { return (false, false) }
        let changed = !report.uploaded.isEmpty || !report.downloaded.isEmpty || !report.deleted.isEmpty
            || !report.arriving.isEmpty || !report.merged.isEmpty
        return (problems.isEmpty, changed)
    }

    /// The network came back: a run soon, without waiting out the backoff of earlier failures.
    func networkReturned() {
        networkDown = false
        networkReturnedAt = now()
        schedule.resetBackoff()
        schedule.demand()
        wake()
    }

    /// The device's network path changed (the coordinator): without one, a WebDAV target's scheduled runs wait.
    func networkChanged(reachable: Bool) {
        guard networkDown == reachable else { return }
        networkDown = !reachable
        if reachable { networkReturnedAt = now() }
        wake()
    }

    // MARK: - Runs

    private func runOnce(maxDuration: TimeInterval? = nil, cancel: SyncRunCancel? = nil, interactive: Bool = false,
                         full: Bool = false) async -> SyncReport? {
        if let running { return await running.value }
        let mode: SyncRunMode = twoWay ? .twoWay : .uploadOnly
        var request = SyncRunRequest(mode: mode, maxDuration: maxDuration, cancels: [cancel, appCancel()].compactMap { $0 })
        request.interactive = interactive
        request.largeBlobs = interactive || full ? .now : .auto
        request.networkReturned = networkReturnedAt
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
                // A write or demand made during a run the loop did not start (Sync Now, a background task) is due now
                // that it ended: the loop computed its sleep while the run went (review of #91, S1).
                wake()
            }
            do {
                let report = try await run(request)
                lastReport = report
                // A run a bound or a cancel cut short after it moved files is progress, not a failure (offline audit
                // P4): no problem shown, no backoff; the next run continues. Only a complete run is a last success.
                let cut = Self.progressedCutShort(report)
                continuing = cut != nil
                // An upload-only run keeps a device list another device changed (`keepServerChanges`):
                // it arrives at the next unlocked run, so it is no problem then.
                let found = WebDAVSyncProblem.from(report: cut ?? report, targetRoots: targetRoots).filter { mode == .twoWay || $0 != .serverChangedManifest }
                problems = found
                failure = nil
                waitingForDeviceUnlock = false
                arriving = report.arriving.count
                let ok = found.isEmpty
                let changed = cut != nil || !report.uploaded.isEmpty || !report.downloaded.isEmpty || !report.deleted.isEmpty
                    || !report.arriving.isEmpty || !report.merged.isEmpty
                schedule.finished(at: now(), success: ok, changed: changed)
                if ok, cut == nil {
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
                continuing = false
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

    /// A report of a run that stopped early after it moved files, because of a cancel (iOS taking the background time
    /// back) or its time bound, or a lost link, with those stops left out of its errors; nil for any other run (offline
    /// audit P4). The engine classifies the stop (`SyncReport.stopReason`): the other run bounds (`maxEntries`,
    /// `maxDownloadBytes`, `maxNotes`) guard against a server that lists or serves without end, so they are `.bound`
    /// and stay failures, shown and backed off (review of #91, M1).
    nonisolated static func progressedCutShort(_ report: SyncReport) -> SyncReport? {
        guard report.stoppedEarly != nil, report.stopReason?.isProgressStop == true, report.madeProgress else { return nil }
        var out = report
        out.errors.removeAll { $0.kind == .stopped || $0.kind == .network }
        return out
    }

    private func recount() async {
        unconfirmed = await countUnconfirmed()
        if let countStaged { staged = await countStaged() }
        if let providerSummary {
            let summary = await providerSummary()
            providerPending = summary.count
            providerError = ProviderUploads.errorText(summary.error)
        }
    }

    // MARK: - Status

    /// The status model (docs/design/device-first-sync.md §8.3).
    var status: SyncStatus {
        SyncStatus(syncing: isSyncing, problems: problems, unconfirmed: unconfirmed, arriving: arriving,
                   twoWay: twoWay, lastSuccess: lastSuccess, folder: kind == .folder, deviceLocked: waitingForDeviceUnlock,
                   staged: staged, networkDown: networkDown && kind == .webdav, continuing: continuing,
                   providerPending: providerPending, viaICloud: uploadsViaICloud, providerError: providerError)
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
        /// The last run moved files and stopped early (a run bound, the background time): the next one continues.
        case continuing
        /// Every change is written into the provider's folder, and this many files wait for the provider (iCloud
        /// Drive) to upload them: written locally, not synced (offline audit P15).
        case waitingForProvider(Int)
        /// The provider reports it cannot upload what was written (a full iCloud storage): a problem.
        case providerFailed(String)
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
    /// A server target while the device has no network path: offline, whatever the last run said.
    var networkDown = false
    /// The last run moved files and was cut short; the next one continues (not a problem).
    var continuing = false
    /// Files written into a provider's folder that it has not uploaded yet (offline audit P15).
    var providerPending = 0
    /// That provider is iCloud Drive.
    var viaICloud = false
    /// The provider's upload error for them, in words (`ProviderUploads.errorText`).
    var providerError: String?

    /// The problem for a run that threw: a folder target's own failures first (a folder that went away
    /// is "not found", one that cannot be reached now is "offline"), then a server's.
    static func problem(from error: Error) -> WebDAVSyncProblem {
        switch error {
        case FolderTargetError.missing: return .notFound
        case FolderTargetError.unavailable: return .offline
        case let e as FolderRemoteError where e.isUnreachable: return .offline   // never a full disk (review of #90, M1)
        case let e where CertificateDate.isDateProblem(e): return .certificate(CertificateDate.refusal)
        default: return WebDAVSyncProblem.from(error: error)
        }
    }

    var kind: Kind {
        if syncing { return .syncing }
        if deviceLocked { return .waitingForUnlock }
        if networkDown || problems.contains(.offline) { return .offline }
        if let problem = problems.first { return .problem(problem) }
        if let providerError { return .providerFailed(providerError) }
        if unconfirmed > 0 { return .pending(unconfirmed) }
        if continuing { return .continuing }
        if providerPending > 0 { return .waitingForProvider(providerPending) }
        if !twoWay { return .waitingForUnlock }
        return .synced
    }

    /// Whether "last sync" may be shown as a sync: not while files wait for the provider, when the last run only
    /// wrote them locally (offline audit P15).
    var lastSuccessIsSync: Bool { providerPending == 0 && providerError == nil }

    /// True when the user should look at it (offline and waiting are not problems).
    var needsAttention: Bool {
        switch kind {
        case .problem, .providerFailed: return true
        default: return false
        }
    }

    var headline: String {
        switch kind {
        case .syncing:
            return folder ? String(localized: "Syncing with the folder…") : String(localized: "Syncing with the server…")
        case .offline:
            if folder {
                return String(localized: "The folder cannot be reached now. Changes are kept on this device and sync when it is back. If it is on a share, Sync Now connects it.")
            }
            return unconfirmed > 0
                ? String(localized: "Offline. \(unconfirmed) changes are kept on this device and sync when the server can be reached.",
                         comment: "Sync status; the number is a count of files")
                : String(localized: "Offline. Changes are kept on this device and sync when the server can be reached.")
        case .pending(let n):
            return String(localized: "\(n) changes not synced yet", comment: "Sync status; the number is a count of files")
        case .continuing:
            return String(localized: "Part of the changes synced. The rest follows at the next sync.",
                          comment: "Sync status: a run stopped early after it moved files")
        case .providerFailed(let text):
            return text
        case .waitingForProvider(let n):
            return viaICloud
                ? String(localized: "\(n) changes waiting for iCloud to upload", comment: "Sync status; the number is a count of files")
                : String(localized: "\(n) changes waiting for the folder's provider to upload", comment: "Sync status; the number is a count of files")
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
                return String(localized: "The folder cannot be reached now. Changes are kept on this device and sync when it is back. If it is on a share, Sync Now connects it.")
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
        case .certificate(let reason):
            // Expired or not yet valid by this device's clock: the clock is the likelier culprit (offline audit P14).
            if CertificateDate.matches(reason) { return CertificateDate.reason }
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
        case .writeGrantLapsed:
            // Not "the folder is gone… Nothing was synced" (re-check of #124): the folder is there, writes were refused.
            return String(localized: "Sempere lost permission to write in this folder. Choose it again in Sync Targets.")
        case .notWritable:
            // Not "errno 13" (build 12): what it means and what to do.
            return String(localized: "Sempere cannot write to this sync folder: this account has no permission to change it (it belongs to another user, or is read-only). The notes on this device are kept. Remove the folder in Sync Targets, or add one you can write to.")
        case .failures(let lines):
            return String(localized: "Some files could not be synced: \(lines.joined(separator: "; "))",
                          comment: "The value lists file paths and errors (English)")
        case .failed(let message):
            return String(localized: "Sync failed: \(message)", comment: "The value is an error message (English)")
        }
    }
}
