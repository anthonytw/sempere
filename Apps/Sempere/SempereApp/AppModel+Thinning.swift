import Foundation
import Sempere

/// How old autosaves must be before thinning removes them (format.md
/// §5.8.4): kept in `UserDefaults` on this device. 0 means never.
enum ThinningPreference {
    static let key = "Sempere.thinAfterDays"
    /// Default: 30 days (maintainer decision, 2026-10-06).
    static let defaultDays = 30
    /// The choices the settings offer, 0 last ("Never").
    static let choices = [7, 14, 30, 90, 365, 0]
    /// Seconds between automatic runs on one vault.
    static let interval: TimeInterval = 24 * 60 * 60

    /// Days, or 0 for never; a stored value outside `choices` reads as its nearest sane value.
    static var days: Int {
        get {
            guard let n = UserDefaults.standard.object(forKey: key) as? Int else { return defaultDays }
            return n <= 0 ? 0 : min(n, 3650)
        }
        set { UserDefaults.standard.set(max(newValue, 0), forKey: key) }
    }

    /// "30 days", "1 year", "Never".
    static func label(_ days: Int) -> String {
        switch days {
        case ...0: return String(localized: "Never", comment: "Thinning: autosaves are never removed (a choice in Settings)")
        case 365: return String(localized: "1 year", comment: "Thinning: remove autosaves older than one year (a choice in Settings)")
        default: return String(localized: "\(days) days", comment: "Thinning: remove autosaves older than this many days (a choice in Settings)")
        }
    }

    /// `UserDefaults` key of the last automatic run on vault `id`.
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
struct NoteThinning: Hashable, Sendable, Identifiable {
    let id: UUID
    var title: String
    /// Revision files deleted (or that would be).
    var deletions: Int
    /// Snapshots written first (or that would be).
    var snapshots: Int
    var bytesDeleted: Int
    var bytesAdded: Int
}

/// The outcome of a thinning pass over the vault.
struct ThinningReport: Hashable, Sendable {
    /// The rule it applied.
    var rule: ThinningRule = .olderThan(days: ThinningPreference.defaultDays)
    /// Notes with something to remove, by title.
    var notes: [NoteThinning] = []
    /// Notes left alone, with why (open in an editor, not downloaded, unreadable revision).
    var skipped: [UUID: String] = [:]
    /// Notes looked at.
    var checked = 0
    /// The time the rule was applied at. Confirming a preview runs with this
    /// time, so the run removes what the preview listed and nothing written
    /// since (with "Thin everything except checkpoints", a newer autosave
    /// would otherwise be in the range too).
    var now: Date?

    var deletions: Int { notes.reduce(0) { $0 + $1.deletions } }
    var snapshots: Int { notes.reduce(0) { $0 + $1.snapshots } }
    var bytesDeleted: Int { notes.reduce(0) { $0 + $1.bytesDeleted } }
    var bytesAdded: Int { notes.reduce(0) { $0 + $1.bytesAdded } }
    var isEmpty: Bool { notes.isEmpty }
}

/// "Checking notes: 120 of 640" while a preview runs, "Thinning notes: …" while a run does.
struct ThinningProgress: Equatable, Sendable {
    var done = 0
    var total = 0
    var dryRun = true

    var fractionCompleted: Double { total == 0 ? 1 : min(1, Double(done) / Double(total)) }
    var headline: String {
        dryRun
            ? String(localized: "Checking notes: \(done) of \(total)", comment: "Thinning preview progress")
            : String(localized: "Thinning notes: \(done) of \(total)", comment: "Thinning progress")
    }
}

extension NoteWriter {
    /// Thins one note as this device (format.md §5.8.4): decides from the
    /// revisions' metadata (the summary cache's, else a read without stroke
    /// geometry) whether anything may go, and only then reads the note in
    /// full, plans on the device clock's actor (a dry run forgets the ticks),
    /// encodes the snapshots once and, unless `dryRun`, writes them and
    /// deletes, inside one coordinated write of the note's folder in iCloud
    /// Drive. `verify` (iCloud: every file local) runs before any read and
    /// inside the write, and throws to refuse the note; a note whose metadata
    /// comes from the cache and shows nothing to delete is not verified, since
    /// nothing of it is read.
    static func thin(_ noteID: UUID, mode: CompactionMode, vault: Vault, clock: DeviceClock, cache: SummaryCache?,
                     app: String = NoteWriter.appName, coordinated: Bool, verify: (@Sendable () throws -> Void)?,
                     dryRun: Bool, now: Date = Date()) async throws -> PreparedCompaction {
        let interval = Perf.begin(.thinNote)
        var stage = "metadata"
        defer { Perf.end(interval, "note=\(Perf.short(noteID)) \(stage)") }
        let empty = PreparedCompaction.nothing(noteID)
        let folder = coordinated ? vault.url.appendingPathComponent("notes", isDirectory: true)
            .appendingPathComponent(noteID.uuidString.lowercased(), isDirectory: true) : nil
        // 1. Metadata only.
        let loaded: LoadedNote? = try await Task.detached(priority: .utility) { () throws -> LoadedNote? in
            let names = try vault.revisionNames(of: noteID)
            if let history = cache?.history(for: noteID, revisions: names),
               !CompactionPlanner.mayDelete(history, noteId: noteID, mode: mode, now: now) {
                return nil
            }
            return try CloudVault.coordinatedRead(coordinated ? vault.url : nil) { () throws -> LoadedNote? in
                try verify?()
                // 2. Something may go: the note in full.
                let loaded = try vault.loadForCompaction(noteID, mode: mode, now: now, cache: cache)
                if loaded != nil { try verify?() }
                return loaded
            }
        }.value
        guard let loaded else { return empty }
        stage = "full"
        let device = clock.device
        let plan = try await clock.withClock(save: !dryRun) { c in
            try vault.planCompaction(noteID, loaded: loaded, mode: mode, now: now, device: device, clock: &c, app: app)
        }
        return try await Task.detached(priority: .utility) {
            let prepared = try vault.prepare(plan)
            if !dryRun, !plan.isEmpty {
                try CloudVault.coordinatedWrite(folder) {
                    try verify?()
                    try vault.execute(prepared)
                }
            }
            return prepared.withoutData
        }.value
    }
}

extension AppModel {
    /// `thinVault(rule:…)` with the configured window: `days` (0 = never, nothing done).
    func thinVault(days: Int, dryRun: Bool, skipOpen: Bool = false, now: Date = Date()) async throws -> ThinningReport {
        guard days > 0 else { return ThinningReport(rule: .olderThan(days: 0)) }
        return try await thinVault(rule: .olderThan(days: days), dryRun: dryRun, skipOpen: skipOpen, now: now)
    }

    /// Thins every note of the open vault by `rule` (format.md §5.8.4): keeps
    /// checkpoints (saved and imported versions) and each editing session's
    /// newest save, deletes the other autosaves the rule covers after writing
    /// the snapshots that keep the kept versions complete. With `dryRun`, only
    /// says what it would do (the preview). Open notes are saved first and
    /// thinned too, unless `skipOpen` (the automatic run leaves them alone).
    /// In iCloud Drive a note whose files are not all local is skipped, never
    /// downloaded. One note's failure skips that note; the others go on.
    ///
    /// Fast on a vault where most notes have nothing to thin: each note is
    /// first judged from its revisions' metadata (`NoteWriter.thin`), which
    /// the summary cache holds once the list has read it, and
    /// `thinningConcurrency` notes are worked on at once. `thinningProgress`
    /// counts the notes done.
    func thinVault(rule: ThinningRule, dryRun: Bool, skipOpen: Bool = false, now: Date = Date()) async throws -> ThinningReport {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        try requireWritableVault()   // format.md §7.3: no thinning, not even a preview
        let gen = generation
        let open = Set([editor?.noteID].compactMap { $0 } + windowEditors.keys)
        if !skipOpen {
            await editor?.flush()
            for e in windowEditors.values { await e.flush() }
        }
        let clock = try deviceClockForWriting()
        let cloud = isCloudVault
        let hooks = cloudHooks
        let url = vault.url
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
        let interval = Perf.begin(.thin)
        var readInFull = 0
        defer { Perf.end(interval, "notes=\(work.count) read=\(readInFull) dryRun=\(dryRun)") }
        var changed: [UUID] = []
        // A real run holds the edit gate throughout (as browser edits and key changes do), so it
        // never interleaves with them; a preview writes nothing and takes no gate.
        if !dryRun { await editGate.acquire() }
        defer { if !dryRun { editGate.release() } }
        try ensureCurrent(gen)
        let tasks = work.map { id in
            let verify: (@Sendable () throws -> Void)? = cloud
                ? { @Sendable in try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) } : nil
            return { @Sendable () async throws -> (UUID, Result<PreparedCompaction, any Error>) in
                do {
                    return (id, .success(try await NoteWriter.thin(id, mode: mode, vault: vault, clock: clock, cache: cache,
                                                                  coordinated: cloud, verify: verify, dryRun: dryRun, now: now)))
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
                report.skipped[id] = "\(error)"
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

    /// Runs thinning in the background when it is on and has not run on this
    /// vault in the last day (`ThinningPreference`). Only an `AppModel` built
    /// with `automaticThinning` does this, so tests write nothing unasked.
    func thinIfDue(now: Date = Date()) {
        // Never in a vault of a newer format version (format.md §7.3).
        guard automaticThinning, phase == .unlocked, !isVaultReadOnly, let id = vault?.vaultId else { return }
        #if DEBUG
        // Scripted runs (screenshots, device probes) must not change the vault they open.
        if DemoLaunch.isActive || DebugLaunch.isActive { return }
        #endif
        let days = ThinningPreference.days
        let key = ThinningPreference.lastRunKey(id)
        guard ThinningPreference.isDue(days: days, lastRun: UserDefaults.standard.object(forKey: key) as? Date, now: now)
        else { return }
        UserDefaults.standard.set(now, forKey: key)
        let gen = generation
        Task(priority: .background) { [weak self] in
            guard let self, self.generation == gen else { return }
            _ = try? await self.thinVault(rule: .olderThan(days: days), dryRun: false, skipOpen: true, now: now)
        }
    }
}
