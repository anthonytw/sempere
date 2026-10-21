import Foundation
import Observation
import Sempere
import SempereSync
import SempereWebDAV

/// One sync target of a store vault, as the coordinator schedules it.
struct SyncTargetRef: Hashable, Sendable, Identifiable {
    /// The store vault.
    let vaultID: UUID
    /// The vault's name, for the bars.
    let vaultName: String
    let target: SyncTarget
    /// The session's key: the target's id.
    var id: UUID { target.id }
}

/// Every in-app vault with a sync target keeps syncing, open or not, each isolated from the others
/// (docs/design/device-first-sync.md §4.2, docs/io.md "Sync targets in the app"). One per app; it owns
/// one `SyncSession` per (vault, target): folder targets (iCloud Drive, any folder) and WebDAV targets,
/// any number per vault.
///
/// - The open vault's sessions run two-way while it is unlocked here (`attachOpen`, `openVaultUnlocked`)
///   and hand each run's local changes to the model. Every other vault's sessions run upload-only at the
///   idle pace (`start`): its captures and last edits go up, and what other devices wrote arrives at its
///   next unlock (nothing unverified is placed in a vault nobody unlocked, design §4.1).
/// - Isolation: each session has its own sync state, quarantine, credentials (Keychain item by target
///   id), schedule, backoff and status. A failure (a hung server bounded by the run's limits, a wrong
///   password, a folder that went away, a full disk) marks only its own session.
/// - Budget: at most `maxConcurrentRuns` runs at once across the app, at most one per session; the open
///   vault's runs go first. Two targets of one vault take turns on the vault's write lock.
@MainActor
@Observable
final class SyncCoordinator {
    /// The sessions, by target id.
    private(set) var sessions: [UUID: SyncSession] = [:]
    /// The vault open in the model, if any.
    private(set) var openVault: UUID?
    /// Whether every target's session runs (the app at launch); off, only the open vault's do (tests).
    private(set) var runsAll = false
    /// The open vault was unlocked here (its sessions are two-way; targets added later are too).
    @ObservationIgnored private var openUnlocked = false

    /// At most this many runs at once across the app.
    @ObservationIgnored var maxConcurrentRuns = 2
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var waiting: [(priority: Bool, resume: CheckedContinuation<Void, Never>)] = []

    /// Builds the session of a target (the model supplies the transport, copy and options).
    @ObservationIgnored var makeSession: @MainActor (SyncTargetRef) -> SyncSession?
    /// The targets there are now, of every store vault.
    @ObservationIgnored var targets: @MainActor () -> [SyncTargetRef]
    /// How often sessions look at their schedules, and their write delay (tests shorten both).
    @ObservationIgnored var tick = Duration.seconds(1)
    @ObservationIgnored var configure: (inout SyncSchedule) -> Void = { _ in }

    init(targets: @escaping @MainActor () -> [SyncTargetRef],
         makeSession: @escaping @MainActor (SyncTargetRef) -> SyncSession?) {
        self.targets = targets
        self.makeSession = makeSession
    }

    // MARK: - Sessions

    /// Starts a session for every target (the app at launch, and after one is added or removed).
    func start() {
        runsAll = true
        refresh()
    }

    /// Makes sessions for new targets (every vault's when `runsAll`, else only the open vault's) and
    /// stops those of removed ones.
    func refresh() {
        let now = targets()
        let ids = Set(now.map { $0.id })
        for id in sessions.keys where !ids.contains(id) { _ = stop(id) }
        for ref in now where sessions[ref.id] == nil && (runsAll || ref.vaultID == openVault) {
            let made = session(for: ref)
            if ref.vaultID == openVault, openUnlocked { made?.vaultUnlocked() }
        }
    }

    /// The session of `ref`, made and started if there is none.
    @discardableResult
    func session(for ref: SyncTargetRef) -> SyncSession? {
        if let existing = sessions[ref.id] { return existing }
        guard let made = makeSession(ref) else { return nil }
        made.tick = tick
        configure(&made.schedule)
        made.admit = { [weak self] priority in await self?.admit(priority: priority) }
        made.release = { [weak self] in self?.releaseRun() }
        sessions[ref.id] = made
        made.start()
        return made
    }

    /// The sessions of vault `id`'s targets, in the order the targets were added.
    func sessions(of id: UUID) -> [SyncSession] {
        sessions.values.filter { $0.vaultID == id }.sorted { $0.added < $1.added }
    }

    /// The model opened vault `id`: its targets' sessions are the open ones (made if needed).
    @discardableResult
    func attachOpen(_ id: UUID) -> [SyncSession] {
        openVault = id
        openUnlocked = false
        for ref in targets() where ref.vaultID == id { session(for: ref) }
        return sessions(of: id)
    }

    /// The open vault was unlocked here: its sessions run two-way from now on, and run now.
    func openVaultUnlocked() {
        guard let openVault else { return }
        openUnlocked = true
        for s in sessions(of: openVault) { s.vaultUnlocked() }
    }

    /// The model closed the open vault: its sessions go back to upload-only (or stop when only the open
    /// vault syncs). Returns the runs still going, which must end before the copy is replaced.
    @discardableResult
    func detachOpen() -> [Task<SyncReport?, Never>] {
        guard let id = openVault else { return [] }
        openVault = nil
        openUnlocked = false
        var running: [Task<SyncReport?, Never>] = []
        for session in sessions(of: id) {
            session.vaultClosed()
            session.onChanges = { _ in }
            if !runsAll {
                if let task = stop(session.locationID) { running.append(task) }
            } else if let task = session.currentRun {
                running.append(task)
            }
        }
        return running
    }

    /// Stops and forgets the session of target `id` (a removed target); returns its run still going.
    @discardableResult
    func stop(_ id: UUID) -> Task<SyncReport?, Never>? {
        guard let session = sessions.removeValue(forKey: id) else { return nil }
        return session.stop()
    }

    /// Something wrote into vault `id` outside the open vault's writers (a quick capture into a closed
    /// vault): its sessions upload soon.
    func vaultWritten(_ id: UUID) {
        for s in sessions(of: id) { s.noteWrite() }
    }

    /// Asks every session for a run soon (the app became active, the network came back).
    func demandAll() {
        for s in sessions.values { s.demand() }
    }

    // MARK: - Budget

    private func admit(priority: Bool) async {
        if active < maxConcurrentRuns {
            active += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if priority, let i = waiting.firstIndex(where: { !$0.priority }) {
                waiting.insert((priority, c), at: i)
            } else {
                waiting.append((priority, c))
            }
        }
    }

    private func releaseRun() {
        if waiting.isEmpty {
            active = max(active - 1, 0)
        } else {
            // The slot passes to the next waiter (the open vault's first).
            waiting.removeFirst().resume.resume()
        }
    }
}
