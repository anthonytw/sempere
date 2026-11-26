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
    /// Told how far the run is (`SyncOptions.progress`, on the sync's threads): the session shows it in the status while the run
    /// goes (`SyncSession.runProgress`).
    var progress: (@Sendable (SyncProgress) -> Void)?
    /// The session's own stop (`SyncSession.interruptRun`): honored once the run's control files are done (`SyncOptions.softCancel`).
    var soft: SyncRunCancel?
    /// A join-check run's window after the control files (`SyncOptions.joinCheckWindow`).
    var joinWindow: TimeInterval?

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
        if let progress { options.progress = progress }
        if let soft { options.softCancel = { soft.isSet } }
        options.joinCheckWindow = joinWindow
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
    /// A failed run the bar does not show.
    public struct QuietFailure: Equatable, Sendable {
        public var message: String
        public var at: Date
    }

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
    /// When the target was last made again (the registry's `SyncTarget.restarted`), if ever.
    var restarted: Date?
    /// Where "has not synced since" counts from when it never synced: the restart, else when the target was added.
    private var neverSyncedSince: Date? { restarted ?? (added == .distantPast ? nil : added) }
    /// When runs happen; the session tells it about writes, demands and runs. Tests shorten its delays.
    public var schedule = SyncSchedule()
    /// A run is going.
    public private(set) var isSyncing = false
    /// What the last run (or the failure that stopped it) reported; empty: all is well.
    public private(set) var problems: [WebDAVSyncProblem] = []
    /// The last run's error message, when it threw.
    private(set) var failure: String?
    /// An iCloud (CloudKit) target's failure that is not shown in the bar (it may heal by itself, design §4): Vault Details
    /// lists it with its time; the 24-hour stall rule (`cloudTracker`) turns one that never clears into a problem.
    public private(set) var quietFailure: QuietFailure?
    /// What a CloudKit run noticed that its report does not say (`CloudRunNotes`); set by the model for those targets.
    var cloudNotes: CloudRunNotes?
    /// Seeded on first use from what the registry persists (`lastSuccess`, `restarted`, `added`), so a relaunch does not restart the 24 hour count.
    private var cloudTrackerStore: CloudStatusTracker?
    private var cloudTracker: CloudStatusTracker {
        get { cloudTrackerStore ?? CloudStatusTracker(lastSuccess: lastSuccess, added: neverSyncedSince) }
        set { cloudTrackerStore = newValue }
    }
    /// How far the run that is going has got (uploads, downloads; nil between runs): the status line says it, so a first upload
    /// of a large vault is seen to move.
    public private(set) var runProgress: SyncProgress?
    /// The files the target had not confirmed when the upload began: the "of M" of an upload (a first upload has no other total).
    /// It holds across the runs of one upload (a join check stops a run every few seconds and the next goes on), until the target has
    /// confirmed every file; more only when notes were written meanwhile.
    @ObservationIgnored private var runUploadTotal = 0
    /// How many of `runUploadTotal` the runs before the one going have confirmed (uploaded, or found on the target already). The
    /// "done" of the status line is this plus what the run going moved (`SyncStatus.movement`).
    @ObservationIgnored private var uploadDoneBefore = 0
    /// `uploadDoneBefore` as the run going began, and whether that run ended whole (not cut short): see `endUploadStep`.
    @ObservationIgnored private var doneAtRunStart = 0
    @ObservationIgnored private var runEndedWhole = false
    /// A run was stopped to make way for the next one (a join check) and the status stays "syncing" until that one starts (or
    /// `handoffHold` passes): the bar never says "continuing" or "not synced yet" for the moment between them.
    private(set) var syncHandoff = false
    @ObservationIgnored private var handoffGeneration = 0
    /// How long the status keeps saying "syncing" for a run that has to follow one (it normally starts within milliseconds).
    @ObservationIgnored var handoffHold: Duration = .seconds(2)
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
    /// The provider's upload error for them once it lasted (`ProviderUploads.Persistence`): the bar says so, as a
    /// problem. Nil while it has not lasted yet: the files are only waiting, as far as the user is told.
    private(set) var providerError: ProviderUploads.State?
    /// The looks in a row that saw an upload error, and since when.
    @ObservationIgnored private(set) var providerTrouble = ProviderUploads.Persistence()
    /// Reads them off the main actor (folder targets; nil: none).
    @ObservationIgnored var providerSummary: (@Sendable () async -> ProviderUploads.Summary)?
    /// Asks the provider again about the files still waiting, off the main actor, and returns what remains (nil: could not
    /// look, try later). The loop calls it between runs while files wait, with growing delays (`providerRecheckDelays`),
    /// so the bar leaves "waiting" when the provider is done, not at the next run.
    @ObservationIgnored var providerRecheck: (@Sendable () async -> ProviderUploads.Summary?)?
    /// The delays between those looks (the last repeats).
    @ObservationIgnored var providerRecheckDelays: [TimeInterval] = [15, 30, 60, 120, 300]
    /// The most looks in a row that find no fewer files waiting (the provider offline): then the loop stops looking
    /// until the next run's count (about 45 minutes with the delays above).
    @ObservationIgnored var providerRecheckLimit = 12
    @ObservationIgnored private var providerRecheckStep = 0
    /// Looks in a row since the waiting count last went down (or since a run's count).
    @ObservationIgnored private var providerRecheckIdle = 0
    /// Runs started so far: a look that a run overlapped keeps its answer to itself (the run's count is newer).
    @ObservationIgnored private var runsStarted = 0
    /// When the loop looks at the waiting files next (`planProviderRecheck`); nil: no look planned.
    @ObservationIgnored private(set) var providerRecheckDue: Date?
    /// How many times the looks stopped after `providerRecheckLimit` in a row (`planProviderRecheck`), and a call each time:
    /// for tests to wait on the plan, never on a quiet spell (review of #90's gate run).
    @ObservationIgnored private(set) var providerLooksStops = 0
    @ObservationIgnored var onProviderLooksStopped: (() -> Void)?
    /// The count `start` makes, for tests to wait on (a later fresh count starts the provider's looks over).
    @ObservationIgnored private(set) var startCount: Task<Void, Never>?
    /// `unconfirmed` was counted at least once.
    @ObservationIgnored private var counted = false
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
    /// The window of a join-check run after its control files (`syncForJoinCheck`): requests and approvals are handled in its first moments, and the caller (Add
    /// Device's look, every 10 s) waits for it to end, so it is short; the loop carries on with the rest of the upload afterwards.
    @ObservationIgnored var joinCheckDuration: TimeInterval = 10
    /// When the run going started (`syncForJoinCheck(since:)`).
    @ObservationIgnored private var runStartedAt: Date?
    /// The cancel flag of the run going (`interruptRun`).
    @ObservationIgnored private var runCancel: SyncRunCancel?
    /// The hard flag of the run going (`interruptRun(hard:)`), one of its `cancels`.
    @ObservationIgnored private var runHardCancel: SyncRunCancel?
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
                if let due = self.providerRecheckDue, self.now() >= due {
                    // A run the loop did not start is going: its count plans the next look; until then the look waits
                    // a step, so the loop does not wake every tick for it.
                    if self.isSyncing { self.postponeProviderRecheck() } else { await self.recheckProvider() }
                }
                guard !Task.isCancelled else { return }
                let nap = Task { [delay = self.sleepDuration()] in _ = try? await Task.sleep(for: delay) }
                self.sleeper = nap
                await nap.value
                if self.sleeper == nap { self.sleeper = nil }
            }
        }
        startCount = Task { await recount() }
    }

    /// A scheduled run may start now: runs are automatic, the pace is not paused (or a write or demand waits), and
    /// a WebDAV target has a network path.
    private var mayRunNow: Bool {
        guard runsAutomatically, !(networkDown && kind.usesNetwork) else { return false }
        return !periodicPaused || schedule.pendingWrite != nil || schedule.demanded
    }

    /// How long the loop sleeps: until the schedule's next run, between `tick` and `maxSleep`; `maxSleep` while
    /// nothing may run (a wake ends it sooner).
    func sleepDuration() -> Duration {
        let floor = tick, ceiling = max(maxSleep ?? tick * 60, tick)
        var wait = ceiling
        if mayRunNow, let next = schedule.nextRun(now: now()) {
            wait = min(max(.milliseconds(Int64(max(0, next.timeIntervalSince(now())) * 1000)), floor), ceiling)
        }
        if let due = providerRecheckDue {
            wait = min(wait, max(.milliseconds(Int64(max(0, due.timeIntervalSince(now())) * 1000)), floor))
        }
        return wait
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

    /// The run `own` was stopped by `interruptRun` and by nothing else (not the background task's `cancel`, not the app-wide flag).
    private func interruptedByUs(_ own: SyncRunCancel, _ cancel: SyncRunCancel?) -> Bool {
        own.isSet && cancel?.isSet != true && appCancel()?.isSet != true
    }

    /// Stops the run going between files (it ends as a run cut short after it moved files: progress, no problem, and the next run
    /// continues). Nothing when no run goes.
    /// With `hard` the stop is honored at once, in any phase (a first feed, a wait for a folder's files, a back-off): for a caller that
    /// is going to remove what the run works on (Delete from iCloud). Without it, only once the run's control files are done
    /// (`SyncOptions.softCancel`).
    func interruptRun(hard: Bool = false) {
        runCancel?.cancel()
        if hard { runHardCancel?.cancel() }
    }

    /// A run for a join check (Add Device looking for a request, approving): a request is picked up early in a run and the approval is
    /// sent early in the next, so a long run already going (a first upload of a large vault, hours at worst) would keep both devices
    /// on their waiting screens (TestFlight 1.4.0 (117), k5). That run is stopped between files, and this one is bounded; the
    /// loop continues the rest afterwards (`demand`).
    @discardableResult
    func syncForJoinCheck(since: Date? = nil) async -> SyncReport? {
        // A run that started after what the check is for (an approval written at `since`) carries it already, early in the run:
        // it is neither stopped nor waited for.
        if let since, running != nil, let started = runStartedAt, started >= since { return nil }
        while let r = running { interruptRun(); _ = await r.value }
        // Bounded by phase, not by the clock alone: the window starts once the control files are done (a first feed of a large zone
        // may take minutes and must not be cut again and again), and `joinCheckSafety` bounds the whole run.
        let report = await runOnce(maxDuration: Self.joinCheckSafety, interactive: true, joinWindow: joinCheckDuration)
        demand()
        return report
    }

    /// The whole of a join-check run is bounded by this, whatever phase it is in.
    static let joinCheckSafety: TimeInterval = 20 * 60

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
                         full: Bool = false, joinWindow: TimeInterval? = nil) async -> SyncReport? {
        if let running { return await running.value }
        let mode: SyncRunMode = twoWay ? .twoWay : .uploadOnly
        let own = SyncRunCancel()
        runCancel = own
        var request = SyncRunRequest(mode: mode, maxDuration: maxDuration, cancels: [cancel, appCancel()].compactMap { $0 })
        request.soft = own
        let hardStop = SyncRunCancel()
        runHardCancel = hardStop
        request.cancels.append(hardStop)
        request.joinWindow = joinWindow
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
            syncHandoff = false
            runStartedAt = now()
            runsStarted += 1
            schedule.started(at: now())
            // The "of M" of an upload: the count must be in before the run starts (a new target's first run starts before it).
            if let startCount { await startCount.value } else if !counted { unconfirmed = await countUnconfirmed(); counted = true }
            beginUploadRun()
            runEndedWhole = false
            // The status may stay "syncing" for the next run only after a normal stop or our own interrupt, never after a failure
            // (an offline upload must show its failure, not "syncing" for the hold).
            var mayHandOff = false
            let relay = WebDAVProgressRelay { [weak self] in self?.runProgress = $0 }
            var request = request
            request.progress = { relay.send($0) }
            defer {
                relay.close()
                // Another run follows at once when this one was stopped for it, or was a join check with files left: the status
                // stays "syncing", and the last progress stays until that run publishes its own.
                if mayHandOff, interruptedByUs(own, cancel) || (joinWindow != nil && (unconfirmed > 0 || continuing)) {
                    holdSyncingForNextRun()
                } else {
                    runProgress = nil
                }
                if runCancel === own { runCancel = nil; runHardCancel = nil }
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
                var assessed = SyncRunAssessment(report: report, twoWay: mode == .twoWay, targetRoots: targetRoots)
                if kind == .cloudkit, cloudNotes?.takeStorageFull() == true {
                    // The account is full: uploads stopped for the run, downloads went on (design §4).
                    assessed.problems = [.cloud(.storageFull)]
                }
                if interruptedByUs(own, cancel), report.stopReason == .cancelled {
                    // Our own `interruptRun` stopped it (a join check), possibly before it moved a file: not a failure, no
                    // problem and no backoff, and not a last success; the next run continues.
                    assessed = SyncRunAssessment(report: SyncReport(), twoWay: mode == .twoWay)
                    assessed.cutShort = true
                }
                continuing = assessed.cutShort
                problems = assessed.problems
                failure = nil
                quietFailure = nil
                if kind == .cloudkit {
                    if assessed.isSuccess { cloudTracker.succeeded(at: now()) }
                }
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
                runEndedWhole = !assessed.cutShort
                mayHandOff = assessed.problems.isEmpty
                await recount()
                return report
            } catch is CancellationError {
                schedule.finished(at: now(), success: false)
                return nil
            } catch where interruptedByUs(own, cancel) && (error as? SyncError) == .cancelled {
                // Thrown rather than reported: the same neutral stop (`interruptRun`).
                continuing = true
                schedule.finished(at: now(), success: true, changed: true)
                mayHandOff = true
                await recount()
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
                failure = WebDAVErrorText.message(error)
                if kind == .cloudkit {
                    problems = cloudProblems(for: error)
                } else {
                    problems = [WebDAVSyncProblem.from(error: error)]
                }
                schedule.finished(at: now(), success: false)
                await recount()
                return nil
            }
        }
        running = task
        return await task.value
    }

    /// An iCloud (CloudKit) target's failed run (design §4): offline, a definite problem, or quiet (listed in Vault Details, and a
    /// problem only when no run succeeded for 24 hours with the network up).
    private func cloudProblems(for error: Error) -> [WebDAVSyncProblem] {
        let at = now()
        cloudTracker.failed(error, networkUp: !networkDown, at: at)
        switch cloudTracker.status(at: at) {
        case .problem(let p):
            quietFailure = nil
            return [.cloud(p)]
        case .offline:
            quietFailure = nil
            return [.offline]
        case .ok, .quiet, .throttled:
            quietFailure = QuietFailure(message: failure ?? "", at: at)
            return []
        }
    }

    /// A report of a run that stopped early after it moved files, with those stops left out of its errors; nil for any
    /// other run (`SyncRunAssessment.progressedCutShort`).
    public nonisolated static func progressedCutShort(_ report: SyncReport) -> SyncReport? {
        SyncRunAssessment.progressedCutShort(report)
    }

    /// The count of an upload when a run starts: a new upload takes what is unconfirmed as its total; one going on keeps its total
    /// and what it has done (more files only raise the total).
    private func beginUploadRun() {
        doneAtRunStart = uploadDoneBefore
        runUploadTotal = max(runUploadTotal, uploadDoneBefore + unconfirmed)
    }

    /// After a run: what the target confirmed is what the copy no longer counts as unconfirmed. At zero the upload is over; so it
    /// is after a run that ended whole (not cut short, `runEndedWhole`) with files still unconfirmed: those never confirm in this
    /// run (an epoch hold, a full account, a refused file), and every later run would show "Uploading 99 of 100". The count is
    /// carried only across runs that were cut short.
    private func endUploadStep() {
        if unconfirmed == 0 || runEndedWhole {
            runUploadTotal = 0
            uploadDoneBefore = 0
        } else {
            uploadDoneBefore = min(max(uploadDoneBefore, runUploadTotal - unconfirmed), runUploadTotal)
        }
    }

    /// The run's progress stays on the status line through the handoff, but what it moved is folded into `uploadDoneBefore` (never
    /// below what the line showed), so the line adds it once, not twice, and never goes back.
    private func holdSyncingForNextRun() {
        if var held = runProgress {
            if !runEndedWhole { uploadDoneBefore = max(uploadDoneBefore, doneAtRunStart + held.uploaded + held.adopted) }
            held.uploaded = 0
            held.adopted = 0
            runProgress = held
        }
        syncHandoff = true
        handoffGeneration += 1
        let generation = handoffGeneration, hold = handoffHold
        Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard let self, self.handoffGeneration == generation, self.syncHandoff else { return }
            self.syncHandoff = false
            if !self.isSyncing { self.runProgress = nil }
        }
    }

    private func recount() async {
        unconfirmed = await countUnconfirmed()
        endUploadStep()
        counted = true
        if let countStaged { staged = await countStaged() }
        if let providerSummary { apply(await providerSummary()) }
        planProviderRecheck(fresh: true)
    }

    private func apply(_ summary: ProviderUploads.Summary) {
        providerPending = summary.count
        // Only an upload error is a problem (`.failed`), and only once it lasted (`ProviderUploads.Persistence`).
        let at = now()
        providerTrouble.observe(summary.error, at: at, networkDown: networkDown)
        let shown = providerTrouble.problem(at: at)
        if providerError != shown { providerError = shown }
    }

    /// While files wait for the provider (or it reports an error), looks at them again between runs, after growing delays;
    /// a fresh count starts the delays over.
    private func planProviderRecheck(fresh: Bool) {
        guard providerRecheck != nil, providerPending > 0 || providerTrouble.isActive else {
            providerRecheckDue = nil
            providerRecheckStep = 0
            return
        }
        if fresh {
            providerRecheckStep = 0
            providerRecheckIdle = 0
        }
        let delays = providerRecheckDelays
        guard !delays.isEmpty, providerRecheckIdle < providerRecheckLimit else {
            providerRecheckDue = nil
            providerLooksStops += 1
            onProviderLooksStopped?()
            return
        }
        providerRecheckDue = now().addingTimeInterval(delays[min(providerRecheckStep, delays.count - 1)])
        providerRecheckStep += 1
    }

    /// The look fell due while a run is going: due again after the current step's delay (the run's count usually
    /// plans it first).
    private func postponeProviderRecheck() {
        let delays = providerRecheckDelays
        guard !delays.isEmpty else { providerRecheckDue = nil; return }
        providerRecheckDue = now().addingTimeInterval(delays[min(max(providerRecheckStep - 1, 0), delays.count - 1)])
    }

    /// One look at the waiting files (`providerRecheck`); the status follows.
    func recheckProvider() async {
        providerRecheckDue = nil
        guard let providerRecheck else { return }
        let before = providerPending
        let runs = runsStarted
        let summary = await providerRecheck()
        // A run started meanwhile counts again when it ends (`recount`), and plans the next look.
        guard runs == runsStarted, !isSyncing else { return }
        if let summary {
            apply(summary)
            providerRecheckIdle = providerPending < before ? 0 : providerRecheckIdle + 1
        } else {
            providerRecheckIdle += 1
        }
        planProviderRecheck(fresh: false)
    }

    // MARK: - Status

    /// The status model (docs/design/device-first-sync.md §8.3).
    public var status: SyncStatus {
        SyncStatus(syncing: isSyncing || syncHandoff, problems: problems, unconfirmed: unconfirmed, arriving: arriving,
                   twoWay: twoWay, lastSuccess: lastSuccess, folder: kind == .folder, deviceLocked: waitingForDeviceUnlock,
                   staged: staged, networkDown: networkDown && kind.usesNetwork, continuing: continuing,
                   providerPending: providerPending, viaICloud: uploadsViaICloud, providerError: providerError,
                   targetName: targetName, added: neverSyncedSince, now: now(), cloudKit: kind == .cloudkit,
                   progress: runProgress, uploadTotal: runUploadTotal, uploadDoneBefore: uploadDoneBefore, lastFailure: quietFailure)
    }

    /// True when something is definitely wrong (`SyncStatus.needsAttention`): the note list shows its bar only then.
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
    public var lastSuccess: Date?
    /// The target is a folder (iCloud Drive, any folder), not a server: the wording says so.
    public var folder = false
    /// The target is iCloud (CloudKit): the wording says so, and there is no "waiting for iCloud to upload" (design §9).
    public var cloudKit = false
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
    /// The target's name (the folder's or the host), for the line of a target unreachable for long (`unreachableDays`).
    public var targetName = ""
    /// When the target was added (the registry's `SyncTarget.added`); nil when unknown. A target that never synced
    /// has been unreachable since then (`unreachableDays`).
    var added: Date?
    /// The time the status was taken (the session's clock): `unreachableDays` counts to it.
    var now: Date
    /// How far the run that is going has got, and the files the target lacked when it started (`SyncSession.runProgress`).
    public var progress: SyncProgress?
    public var uploadTotal = 0
    /// Files of `uploadTotal` that earlier runs of this upload confirmed (`SyncSession.uploadDoneBefore`).
    public var uploadDoneBefore = 0
    /// A failure of the last run that the status does not call a problem (an iCloud run that may heal by itself): shown beside
    /// "N changes not synced yet", so a stalled first upload is not silent.
    public var lastFailure: SyncSession.QuietFailure?

    /// How long a target may stay unreachable before it needs attention (`unreachableDays`): offline for an hour is
    /// normal, for a week the user should look (a server gone, a renamed host, a share never mounted again).
    public static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    public init(syncing: Bool, problems: [WebDAVSyncProblem], unconfirmed: Int, arriving: Int, twoWay: Bool, lastSuccess: Date?,
                folder: Bool = false, deviceLocked: Bool = false, staged: Int = 0, networkDown: Bool = false,
                continuing: Bool = false, providerPending: Int = 0, viaICloud: Bool = false,
                providerError: ProviderUploads.State? = nil, targetName: String = "", added: Date? = nil,
                now: Date = Date(), cloudKit: Bool = false, progress: SyncProgress? = nil, uploadTotal: Int = 0,
                uploadDoneBefore: Int = 0, lastFailure: SyncSession.QuietFailure? = nil) {
        self.progress = progress
        self.uploadTotal = uploadTotal
        self.uploadDoneBefore = uploadDoneBefore
        self.lastFailure = lastFailure
        self.cloudKit = cloudKit
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
        self.targetName = targetName
        self.added = added
        self.now = now
    }

    /// The problem for a run that threw (`WebDAVSyncProblem.from(error:)`, the one classification the CLI reads too).
    public static func problem(from error: Error) -> WebDAVSyncProblem { WebDAVSyncProblem.from(error: error) }

    public var kind: Kind {
        if syncing { return .syncing }
        return settledKind
    }

    /// What the run that is going is moving, for the status line ("Uploading 120 of 340 files…"); nil when it has moved nothing
    /// yet (listing, comparing) or no run goes. Uploads count against the files the target lacked at the start (a first upload
    /// has no other total; more than that, because notes were written meanwhile, shows no total).
    public enum Movement: Equatable, Sendable {
        case uploading(done: Int, of: Int?)
        case downloading(done: Int, of: Int)
    }

    public var movement: Movement? {
        guard syncing, let p = progress else { return nil }
        // This run's uploads and the files it found on the target already, after those earlier runs of the upload confirmed.
        let moved = p.uploaded + p.adopted
        let downloading = p.filesTotal > 0 && p.filesDone < p.filesTotal
        if moved > 0 || (uploadDoneBefore > 0 && !downloading) {
            let done = uploadDoneBefore + moved
            // More went up than were counted as waiting (notes written meanwhile): no total, never "X of M" with X over M.
            if uploadTotal >= done, uploadTotal > 0 { return .uploading(done: done, of: uploadTotal) }
            if done > 0 { return .uploading(done: done, of: nil) }
        }
        if p.filesTotal > 0, p.filesDone < p.filesTotal { return .downloading(done: p.filesDone, of: p.filesTotal) }
        return nil
    }

    /// What the status is apart from a run going: a problem the last run (or the provider) reported stays while the next
    /// run goes, so the bar that shows it does not come and go with every run.
    public var settledKind: Kind {
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

    /// True when something is definitely wrong and the user should look at it; the note list shows its bar only then
    /// (owner 2026-11-20: the status ever present at the bottom of the notes was annoying). A problem a run reported
    /// (a refused password or certificate, a folder gone or not writable, files that failed, a device-list conflict) and
    /// a provider's upload error that lasted (`ProviderUploads.Persistence`) are; syncing, synced, changes not synced
    /// yet, a run cut short, files waiting for the provider, waiting for the unlock and offline (changes are kept on this
    /// device, and sync when it is back) are not, except a target the last runs could not reach for `staleAfter` while
    /// the device had a network (`unreachableDays`). Judged on `settledKind`: a problem stays one while the next run goes.
    public var needsAttention: Bool {
        switch settledKind {
        case .problem, .providerFailed: return true
        default: return unreachableDays != nil
        }
    }

    /// Whole days the target has not been reached, when that is at least `staleAfter` and the runs, not the device's
    /// network, said so (`.offline` also covers a host not found or unreachable, timeouts and a folder that is not
    /// there, `WebDAVSyncProblem.from(error:)`); nil otherwise. Counted from the last sync, or, for a target that never
    /// synced, from when it was added (`added`, the registry's date: the first run is tried as soon as a target is
    /// added); a target whose date is unknown is not counted.
    public var unreachableDays: Int? {
        guard settledKind == .offline, !networkDown, problems.contains(.offline),
              let since = lastSuccess ?? added else { return nil }
        let age = now.timeIntervalSince(since)
        guard age >= Self.staleAfter else { return nil }
        return Int(age / (24 * 60 * 60))
    }
}

/// What a CloudKit target's run saw that its report does not carry (the model's run closure writes, the session reads after
/// the run): the account's storage was full.
public final class CloudRunNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var storageFull = false

    public init() {}

    public func noteStorageFull() { lock.lock(); storageFull = true; lock.unlock() }

    /// True once after `noteStorageFull`.
    func takeStorageFull() -> Bool { lock.lock(); defer { lock.unlock() }; let v = storageFull; storageFull = false; return v }
}
