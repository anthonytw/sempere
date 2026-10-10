import Foundation
import Observation
import Sempere
import SempereWebDAV

/// The push-only sync of the open WebDAV vault (docs/io.md, "WebDAV vaults
/// in the app"): when to push (`WebDAVPushSchedule`), one run at a time, and
/// what the note list's bar says. The model owns it from `openWebDAV` to `close`.
@MainActor
@Observable
final class WebDAVSession {
    let locationID: UUID
    /// The vault's name, for the bar.
    let name: String
    /// When pushes run; the session tells it about writes, demands and runs.
    /// Tests shorten its delays.
    var schedule = WebDAVPushSchedule()
    /// A push is running.
    private(set) var isPushing = false
    /// What the last run (or the failure that stopped it) reported; empty: all is well.
    private(set) var problems: [WebDAVSyncProblem] = []
    /// The last run's error message, when it threw.
    private(set) var failure: String?
    /// Files of the local copy the server has not confirmed (recounted after each run and write).
    private(set) var unconfirmed = 0
    /// Files on the server another writer added (kept, never downloaded).
    private(set) var otherWriterFiles = 0
    /// When a push last finished without problems.
    private(set) var lastPush: Date?
    /// Pushes need the vault unlocked (deletions are checked against it).
    private(set) var unlocked = false

    /// Runs one push off the main actor and returns its report (the model
    /// supplies it: endpoint, copy, vault).
    @ObservationIgnored let push: @Sendable () async throws -> SyncReport
    /// Counts the copy's unconfirmed files off the main actor.
    @ObservationIgnored let countUnconfirmed: @Sendable () async -> Int
    /// Told when a run ends without problems (the model stores `lastPush`).
    @ObservationIgnored var onSuccess: (Date) -> Void = { _ in }
    @ObservationIgnored var now: () -> Date = { Date() }
    /// How often the loop looks at the schedule.
    @ObservationIgnored var tick = Duration.seconds(1)
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var running: Task<SyncReport?, Never>?

    init(locationID: UUID, name: String, lastPush: Date?,
         push: @escaping @Sendable () async throws -> SyncReport,
         countUnconfirmed: @escaping @Sendable () async -> Int) {
        self.locationID = locationID
        self.name = name
        self.lastPush = lastPush
        self.push = push
        self.countUnconfirmed = countUnconfirmed
    }

    // MARK: - Lifecycle

    /// Starts the loop. Nothing is pushed until `vaultUnlocked`.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.unlocked, self.schedule.isDue(now: self.now()) { _ = await self.runOnce() }
                try? await Task.sleep(for: self.tick)
            }
        }
        Task { await recount() }
    }

    /// Stops the loop; a run in progress finishes (it changes only the server).
    func stop() {
        loop?.cancel()
        loop = nil
        unlocked = false
    }

    /// The vault was unlocked: push now.
    func vaultUnlocked() {
        unlocked = true
        schedule.demand()
    }

    // MARK: - Events

    /// A delta or blob was written to the copy.
    func noteWrite() {
        schedule.noteWrite(at: now())
        unconfirmed += 1
    }

    /// Push as soon as possible (the app became active).
    func demand() { schedule.demand() }

    /// "Sync Now": runs a push (after the one running, if any) and returns
    /// its report; nil when it threw (`failure` says why) or the vault is locked.
    @discardableResult
    func pushNow() async -> SyncReport? {
        guard unlocked else { return nil }
        // A run in flight may predate the change asked for: wait for it, then run anew.
        while let running { _ = await running.value }
        return await runOnce()
    }

    // MARK: - Runs

    private func runOnce() async -> SyncReport? {
        if let running { return await running.value }
        let task = Task { () -> SyncReport? in
            isPushing = true
            schedule.started(at: now())
            defer {
                isPushing = false
                running = nil   // cleared by the run itself, so a waiter never takes a finished run for a current one
            }
            do {
                let report = try await push()
                let found = WebDAVSyncProblem.from(report: report)
                problems = found
                failure = nil
                otherWriterFiles = report.extraneous.count
                schedule.finished(at: now(), success: found.isEmpty || found == [.serverChangedManifest])
                if found.isEmpty || found == [.serverChangedManifest] {
                    lastPush = now()
                    onSuccess(lastPush ?? now())
                }
                await recount()
                return report
            } catch is CancellationError {
                schedule.finished(at: now(), success: false)
                return nil
            } catch {
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

    private func recount() async {
        unconfirmed = await countUnconfirmed()
    }

    // MARK: - Status

    /// True when the bar has something to say beyond "up to date".
    var needsAttention: Bool { !problems.isEmpty && problems != [.offline] }

    /// The bar's line.
    var headline: String {
        if isPushing { return String(localized: "Uploading to the server…") }
        let changeCount = unconfirmed
        if problems.contains(.offline) {
            return changeCount > 0
                ? String(localized: "Offline. \(changeCount) changes are kept on this device and uploaded when the server can be reached.",
                         comment: "WebDAV status; the number is a count of files")
                : String(localized: "Offline. Changes are kept on this device and uploaded when the server can be reached.")
        }
        if let problem = problems.first { return Self.text(for: problem) }
        if changeCount > 0 {
            return String(localized: "\(changeCount) changes not uploaded yet", comment: "WebDAV status; the number is a count of files")
        }
        return String(localized: "Up to date on the server")
    }

    /// What to do about a problem.
    static func text(for problem: WebDAVSyncProblem) -> String {
        switch problem {
        case .offline:
            return String(localized: "Offline. Changes are kept on this device and uploaded when the server can be reached.")
        case .unauthorized:
            return String(localized: "The server refused the user name or password. Update the password.")
        case .certificate:
            return String(localized: "The server's certificate is not trusted or changed. Check the server, then trust its certificate again.")
        case .otherVault:
            return String(localized: "The server folder now holds another vault. Nothing was uploaded.")
        case .notFound:
            return String(localized: "The server folder is gone. Nothing was uploaded.")
        case .redirect(let target):
            return String(localized: "The server redirects to \(target). Connect to that address instead.",
                          comment: "The value is a URL")
        case .serverChangedManifest:
            return String(localized: "The vault's device list on the server was changed elsewhere. It was kept; notes still upload. Download the vault again to get the change.")
        case .failures(let lines):
            return String(localized: "Some files could not be uploaded: \(lines.joined(separator: "; "))",
                          comment: "The value lists file paths and errors (English)")
        case .failed(let message):
            return String(localized: "Upload failed: \(message)", comment: "The value is an error message (English)")
        }
    }
}
