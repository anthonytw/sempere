import Foundation
import Observation
import Sempere
import SempereSync
import SempereWebDAV

/// An error that only says the device has not been unlocked since it started (the Keychain refuses the WebDAV
/// password until then): a run that throws it waits for the unlock, with no problem shown and no backoff (review of
/// #74, B1). The app's password store's error conforms.
protocol DeviceUnlockWaiting: Error {
    var waitsForDeviceUnlock: Bool { get }
}

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
public struct SyncRunRequest: Sendable {
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

    init(mode: SyncRunMode, maxDuration: TimeInterval? = nil, stage: Bool = false, cancels: [SyncRunCancel] = [],
                interactive: Bool = false, networkReturned: Date? = nil, largeBlobs: LargeBlobPolicy = .auto) {
        self.mode = mode
        self.maxDuration = maxDuration
        self.stage = stage
        self.cancels = cancels
        self.interactive = interactive
        self.networkReturned = networkReturned
        self.largeBlobs = largeBlobs
    }

    /// Applies the bounds to a run's options (the time bound through `SyncBounds`, as the CLI's `--max-minutes`).
    func apply(to options: inout SyncOptions) {
        SyncBounds(maxDuration: maxDuration).apply(to: &options)
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

    init() {}

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
public final class SyncSession {
    /// The target's id (a `SyncTarget`, which a WebDAV location also is).
    public let locationID: UUID
    /// The vault (its `vaultId`), when known.
    let vaultID: UUID?
    /// The vault's name, for the bar.
    let name: String
    /// The target's kind: the bar's wording (a folder or a server).
    public var kind = SyncTargetKind.webdav
    /// The target's name (the folder's or the host), for the target list.
    public var targetName = ""
    /// When the target was added (the order of a vault's sessions).
    var added = Date.distantPast
    /// When runs happen; the session tells it about writes, demands and runs. Tests shorten its delays.
    public var schedule = SyncSchedule()
    /// A run is going.
    public private(set) var isSyncing = false
    /// What the last run (or the failure that stopped it) reported; empty: all is well.
    public private(set) var problems: [WebDAVSyncProblem] = []
    /// The last run's error message, when it threw.
    private(set) var failure: String?
    /// Files of the local copy the target has not confirmed (recounted after each run and write).
    private(set) var unconfirmed = 0
    /// When a run last finished without problems.
    public private(set) var lastSuccess: Date?
    /// Runs are two-way: the vault is open and unlocked here.
    private(set) var twoWay = false
    /// What the last run did, for "Show Details" and tests.
    private(set) var lastReport: SyncReport?
    /// The join requests the target held at the last run that reached `joins/` (`SyncReport.joinsHeld`): a later run
    /// cut short before it has none to report, and must not turn "sent" back into "sending".
    private(set) var lastJoinsHeld: [String]?
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
    private(set) var providerError: ProviderUploads.State?
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
    /// The device has no network path now (the app's path monitor, through the coordinator): a WebDAV target's scheduled
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

    public init(locationID: UUID, vaultID: UUID?, name: String, lastSuccess: Date?,
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
    public func stop() -> Task<SyncReport?, Never>? {
        loop?.cancel()
        loop = nil
        wake()
        twoWay = false
        return running
    }

    /// The vault was unlocked here: runs are two-way from now on, and one runs now.
    public func vaultUnlocked() {
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
    public func demand() {
        schedule.demand()
        wake()
    }

    /// "Sync Now": runs (after the run going, if any) and returns its report; nil when it threw
    /// (`failure` says why).
    @discardableResult
    public func syncNow() async -> SyncReport? {
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
                if let held = report.joinsHeld { lastJoinsHeld = held }
                // A run a bound or a cancel cut short after it moved files is progress, not a failure (offline audit
                // P4): no problem shown, no backoff; the next run continues. Only a complete run is a last success.
                // An upload-only run keeps a device list another device changed (`keepServerChanges`):
                // it arrives at the next unlocked run, so it is no problem then (`SyncRunAssessment`).
                let assessed = SyncRunAssessment(report: report, twoWay: mode == .twoWay, targetRoots: targetRoots)
                continuing = assessed.cutShort
                problems = assessed.problems
                failure = nil
                waitingForDeviceUnlock = false
                arriving = report.arriving.count
                let ok = assessed.problems.isEmpty
                let changed = assessed.cutShort || !report.uploaded.isEmpty || !report.downloaded.isEmpty || !report.deleted.isEmpty
                    || !report.arriving.isEmpty || !report.merged.isEmpty
                schedule.finished(at: now(), success: ok, changed: changed)
                if assessed.isSuccess {
                    lastSuccess = now()
                    onSuccess(lastSuccess ?? now())
                }
                if mode == .twoWay, let changes = report.changed, !changes.isEmpty { onChanges(changes) }
                await recount()
                return report
            } catch is CancellationError {
                schedule.finished(at: now(), success: false)
                return nil
            } catch let e as any DeviceUnlockWaiting where e.waitsForDeviceUnlock {
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
                problems = [WebDAVSyncProblem.from(error: error)]
                failure = WebDAVErrorText.message(error)
                schedule.finished(at: now(), success: false)
                await recount()
                return nil
            }
        }
        running = task
        return await task.value
    }

    /// A report of a run that stopped early after it moved files, with those stops left out of its errors; nil for any
    /// other run (`SyncRunAssessment.progressedCutShort`).
    public nonisolated static func progressedCutShort(_ report: SyncReport) -> SyncReport? {
        SyncRunAssessment.progressedCutShort(report)
    }

    private func recount() async {
        unconfirmed = await countUnconfirmed()
        if let countStaged { staged = await countStaged() }
        if let providerSummary {
            let summary = await providerSummary()
            providerPending = summary.count
            // Only an upload error is a problem (`.failed`).
            if case .failed? = summary.error { providerError = summary.error } else { providerError = nil }
        }
    }

    // MARK: - Status

    /// The status model (docs/design/device-first-sync.md §8.3).
    public var status: SyncStatus {
        SyncStatus(syncing: isSyncing, problems: problems, unconfirmed: unconfirmed, arriving: arriving,
                   twoWay: twoWay, lastSuccess: lastSuccess, folder: kind == .folder, deviceLocked: waitingForDeviceUnlock,
                   staged: staged, networkDown: networkDown && kind == .webdav, continuing: continuing,
                   providerPending: providerPending, viaICloud: uploadsViaICloud, providerError: providerError)
    }

    /// True when the bar has something to say beyond "synced".
    public var needsAttention: Bool { status.needsAttention }
}

/// What the note list's bar and the library say about one (vault, target) pair (docs/design/
/// device-first-sync.md §8.3): synced, syncing, offline, waiting for the unlock, or a problem. Pure
/// (the session's state in, a `Kind` out), so it is tested without a run; the app words it (`headline`).
public struct SyncStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
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
        /// The provider reports it cannot upload what was written (a full iCloud storage): a problem. Always a
        /// `.failed` state.
        case providerFailed(ProviderUploads.State)
        /// The vault is closed or locked here: what other devices changed arrives at the next unlock.
        case waitingForUnlock
        case problem(WebDAVSyncProblem)
        case synced
    }

    var syncing: Bool
    var problems: [WebDAVSyncProblem]
    public var unconfirmed: Int
    public var arriving: Int
    var twoWay: Bool
    var lastSuccess: Date?
    /// The target is a folder (iCloud Drive, any folder), not a server: the wording says so.
    public var folder = false
    /// The last run waited for the device's first unlock (its password could not be read yet).
    var deviceLocked = false
    /// Files from other devices staged for the next unlock (`LockedStaging`).
    public var staged = 0
    /// A server target while the device has no network path: offline, whatever the last run said.
    var networkDown = false
    /// The last run moved files and was cut short; the next one continues (not a problem).
    var continuing = false
    /// Files written into a provider's folder that it has not uploaded yet (offline audit P15).
    var providerPending = 0
    /// That provider is iCloud Drive.
    public var viaICloud = false
    /// The provider's upload error for them (a `.failed` state; the app words it).
    var providerError: ProviderUploads.State?

    public init(syncing: Bool, problems: [WebDAVSyncProblem], unconfirmed: Int, arriving: Int, twoWay: Bool, lastSuccess: Date?,
                folder: Bool = false, deviceLocked: Bool = false, staged: Int = 0, networkDown: Bool = false,
                continuing: Bool = false, providerPending: Int = 0, viaICloud: Bool = false,
                providerError: ProviderUploads.State? = nil) {
        self.syncing = syncing
        self.problems = problems
        self.unconfirmed = unconfirmed
        self.arriving = arriving
        self.twoWay = twoWay
        self.lastSuccess = lastSuccess
        self.folder = folder
        self.deviceLocked = deviceLocked
        self.staged = staged
        self.networkDown = networkDown
        self.continuing = continuing
        self.providerPending = providerPending
        self.viaICloud = viaICloud
        self.providerError = providerError
    }

    /// The problem for a run that threw (`WebDAVSyncProblem.from(error:)`, the one classification the CLI reads too).
    public static func problem(from error: Error) -> WebDAVSyncProblem { WebDAVSyncProblem.from(error: error) }

    public var kind: Kind {
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
    public var lastSuccessIsSync: Bool { providerPending == 0 && providerError == nil }

    /// True when the user should look at it (offline and waiting are not problems).
    public var needsAttention: Bool {
        switch kind {
        case .problem, .providerFailed: return true
        default: return false
        }
    }
}
