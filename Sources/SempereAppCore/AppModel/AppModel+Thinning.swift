import Foundation
import Sempere

/// How old autosaves must be before thinning removes them (format.md
/// §5.8.4): kept in the device's settings (`UserDefaults` in the app). 0 means never. Its words (`label`) are the app's.
public enum ThinningPreference {
    public static let key = "Sempere.thinAfterDays"
    /// Default: 30 days (maintainer decision, 2026-10-06).
    public static let defaultDays = 30
    /// The choices the settings offer, 0 last ("Never").
    public static let choices = [7, 14, 30, 90, 365, 0]
    /// Seconds between automatic runs on one vault.
    static let interval: TimeInterval = 24 * 60 * 60

    /// Days, or 0 for never; a stored value outside `choices` reads as its nearest sane value.
    static func days(in settings: any KeyValueStore) -> Int {
        guard let n = settings.object(forKey: key) as? Int else { return defaultDays }
        return n <= 0 ? 0 : min(n, 3650)
    }

    /// The settings key of the last automatic run on vault `id`.
    static func lastRunKey(_ id: UUID) -> String { "Sempere.lastThinning.\(id.uuidString.lowercased())" }

    /// Whether an automatic run is due: thinning is on and the last run on
    /// this vault was `interval` or more ago (or never, or in the future).
    static func isDue(days: Int, lastRun: Date?, now: Date) -> Bool {
        guard days > 0 else { return false }
        guard let lastRun, lastRun <= now else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }
}

/// What thinning does (or would do) to one note.
public struct NoteThinning: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    /// Revision files deleted (or that would be).
    public var deletions: Int
    /// Snapshots written first (or that would be).
    var snapshots: Int
    var bytesDeleted: Int
    var bytesAdded: Int

    public init(id: UUID, title: String, deletions: Int, snapshots: Int, bytesDeleted: Int, bytesAdded: Int) {
        self.id = id
        self.title = title
        self.deletions = deletions
        self.snapshots = snapshots
        self.bytesDeleted = bytesDeleted
        self.bytesAdded = bytesAdded
    }
}

/// The outcome of a thinning pass over the vault.
public struct ThinningReport: Hashable, Sendable {
    /// The rule it applied.
    public var rule: ThinningRule = .olderThan(days: ThinningPreference.defaultDays)
    /// Notes with something to remove, by title.
    public var notes: [NoteThinning] = []
    /// Notes left alone, with why (open in an editor, not downloaded, unreadable revision).
    public var skipped: [UUID: String] = [:]
    /// Notes looked at.
    var checked = 0
    /// The time the rule was applied at. Confirming a preview runs with this
    /// time, so the run removes what the preview listed and nothing written
    /// since (with "Thin everything except checkpoints", a newer autosave
    /// would otherwise be in the range too).
    public var now: Date?

    public init(rule: ThinningRule = .olderThan(days: ThinningPreference.defaultDays), notes: [NoteThinning] = [],
                skipped: [UUID: String] = [:], checked: Int = 0, now: Date? = nil) {
        self.rule = rule
        self.notes = notes
        self.skipped = skipped
        self.checked = checked
        self.now = now
    }

    public var deletions: Int { notes.reduce(0) { $0 + $1.deletions } }
    public var snapshots: Int { notes.reduce(0) { $0 + $1.snapshots } }
    public var bytesDeleted: Int { notes.reduce(0) { $0 + $1.bytesDeleted } }
    public var bytesAdded: Int { notes.reduce(0) { $0 + $1.bytesAdded } }
    public var isEmpty: Bool { notes.isEmpty }
}

/// How far a thinning preview (`dryRun`) or run has got, per note; the app words it ("Checking notes: 120 of 640",
/// "Thinning notes: …").
public struct ThinningProgress: Equatable, Sendable {
    public var done = 0
    public var total = 0
    public var dryRun = true

    public init(done: Int = 0, total: Int = 0, dryRun: Bool = true) {
        self.done = done
        self.total = total
        self.dryRun = dryRun
    }

    public var fractionCompleted: Double { total == 0 ? 1 : min(1, Double(done) / Double(total)) }
}

extension AppModelCore {
    /// `thinVault(rule:…)` with the configured window: `days` (0 = never, nothing done).
    public func thinVault(days: Int, dryRun: Bool, skipOpen: Bool = false, now: Date = Date()) async throws -> ThinningReport {
        guard days > 0 else { return ThinningReport(rule: .olderThan(days: 0)) }
        return try await thinVault(rule: .olderThan(days: days), dryRun: dryRun, skipOpen: skipOpen, now: now)
    }

    /// Thins every note of the open vault by `rule` (format.md §5.8.4): keeps
    /// checkpoints (saved and imported versions) and each editing session's
    /// newest save, deletes the other autosaves the rule covers after writing
    /// the snapshots that keep the kept versions complete. With `dryRun`, only
    /// says what it would do (the preview). Open notes are saved first and
    /// thinned too, unless `skipOpen` (the automatic run leaves them alone,
    /// also those opened while it runs).
    /// In iCloud Drive a note whose files are not all local is skipped, never
    /// downloaded. One note's failure skips that note; the others go on.
    ///
    /// Fast on a vault where most notes have nothing to thin: each note is
    /// first judged from its revisions' metadata (`NoteWriter.thin`), which
    /// the summary cache holds once the list has read it, and
    /// `thinningConcurrency` notes are worked on at once. `thinningProgress`
    /// counts the notes done.
    public func thinVault(rule: ThinningRule, dryRun: Bool, skipOpen: Bool = false, now: Date = Date()) async throws -> ThinningReport {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        try requireWritableVault()   // format.md §7.3: no thinning, not even a preview
        // While a join fills the copy, thinning waits (design §8.2): its notes are not all here.
        if partialCopyRoot != nil { throw joinNotDownloadedError }
        let gen = generation
        let open = Set([editor?.noteID].compactMap { $0 } + windowEditors.keys + openingNoteIDs.keys)
        if !skipOpen {
            await editor?.flush()
            for e in windowEditors.values { await e.flush() }
        }
        let clock = try deviceClockForWriting()
        let cache = summaryCache
        let mode = rule.mode
        let titles = Dictionary(notes.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let ids = try await offMain(priority: .utility) { try vault.noteIDs() }
        try ensureCurrent(gen)
        var report = ThinningReport(rule: rule, now: now)
        let work = ids.filter { !(skipOpen && open.contains($0)) }
        for id in ids where skipOpen && open.contains(id) { report.skipped[id] = "open" }
        thinningProgress = ThinningProgress(done: 0, total: work.count, dryRun: dryRun)
        defer { if generation == gen { thinningProgress = nil } }
        let perf = services.perf
        let interval = perf.begin("thin")
        var readInFull = 0
        defer { perf.end(interval, "notes=\(work.count) read=\(readInFull) dryRun=\(dryRun)") }
        var changed: [UUID] = []
        // A real run holds the edit gate throughout (as browser edits and key changes do), so it
        // never interleaves with them; a preview writes nothing and takes no gate.
        if !dryRun { await editGate.acquire() }
        defer { if !dryRun { editGate.release() } }
        try ensureCurrent(gen)
        let tasks = work.map { id in
            // A note opened since the run started is left alone too (asked again before anything is written).
            let isOpen: (@Sendable () async -> Bool)? = skipOpen
                ? { @Sendable [weak self] in await self?.isNoteOpen(id) ?? true } : nil
            return { @Sendable () async throws -> (UUID, Result<PreparedCompaction, any Error>) in
                do {
                    if let isOpen, await isOpen() { throw ThinningSkippedOpen() }
                    return (id, .success(try await NoteWriter.thin(id, mode: mode, vault: vault, clock: clock, cache: cache,
                                                                  coordinated: false, verify: nil, dryRun: dryRun, now: now,
                                                                  perf: perf, isOpen: isOpen)))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return (id, .failure(error))
                }
            }
        }
        let width = max(1, thinningConcurrency)
        var results: [(UUID, Result<PreparedCompaction, any Error>)] = []
        try await withThrowingTaskGroup(of: (UUID, Result<PreparedCompaction, any Error>).self) { group in
            var next = 0
            while next < min(width, tasks.count) {
                group.addTask(operation: tasks[next])
                next += 1
            }
            while let done = try await group.next() {
                results.append(done)
                thinningProgress?.done = results.count
                if next < tasks.count {
                    group.addTask(operation: tasks[next])
                    next += 1
                }
            }
        }
        report.checked = results.count
        for (id, result) in results {
            switch result {
            case .success(let p):
                if !p.plan.targets.isEmpty || !p.plan.deletions.isEmpty { readInFull += 1 }
                guard !p.plan.deletions.isEmpty else { continue }
                report.notes.append(NoteThinning(id: id, title: titles[id] ?? "", deletions: p.plan.deletions.count,
                                                 snapshots: p.plan.snapshots.count, bytesDeleted: p.bytesDeleted,
                                                 bytesAdded: p.bytesAdded))
                if !dryRun { changed.append(id) }
            case .failure(let error):
                report.skipped[id] = services.describeError(error)
            }
        }
        try ensureCurrent(gen)
        report.notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        // The metadata read for notes the index did not have is kept for the next run.
        saveSummaryCache()
        if !changed.isEmpty {
            try? await refresh(changed)
            for id in changed where open.contains(id) && !skipOpen { try? await reopenEditor(ifShowing: id) }
        }
        return report
    }

    /// Whether note `id` is open in an editor or a note window (or one is opening it).
    func isNoteOpen(_ id: UUID) -> Bool {
        editor?.noteID == id || windowEditors[id] != nil || windowClaims.contains(id) || openingNoteIDs[id] != nil
    }

    /// Runs thinning in the background when it is on and has not run on this
    /// vault in the last day (`ThinningPreference`, in `services.settings`). Only an `AppModel` built
    /// with `automaticThinning` does this, so tests write nothing unasked (nor do the app's scripted runs:
    /// screenshots and device probes must not change the vault they open). After every listing `unlock` starts.
    func thinIfDue(now: Date = Date()) {
        // Never in a vault of a newer format version (format.md §7.3).
        guard automaticThinning, phase == .unlocked, !isVaultReadOnly, partialCopyRoot == nil,
              let id = vault?.vaultId else { return }
        let settings = services.settings
        let days = ThinningPreference.days(in: settings)
        let key = ThinningPreference.lastRunKey(id)
        guard ThinningPreference.isDue(days: days, lastRun: settings.object(forKey: key) as? Date, now: now)
        else { return }
        settings.set(now, forKey: key)
        let gen = generation
        automaticThinningRun = Task(priority: .background) { [weak self] in
            guard let self, self.generation == gen else { return }
            _ = try? await self.thinVault(rule: .olderThan(days: days), dryRun: false, skipOpen: true, now: now)
        }
    }
}
