import Foundation

// Thinning one note as this device (format.md §5.8.4), the async way the app runs it: the same stages as
// `Vault.prepareCompaction` (what the CLI's `compact` runs on threads), with the seams a provider-coordinated
// folder and an open editor need. The two paths are pinned to the same plan by `NoteThinningTests`.

/// Thinning left a note alone because it was opened while the automatic
/// run was under way (`thinVault(skipOpen:)`); reported like a note open
/// when the run started.
public struct ThinningSkippedOpen: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "open" }
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
    /// nothing of it is read. `isOpen` is asked once the plan is made, before
    /// anything is written: true leaves the note alone (`ThinningSkippedOpen`). The snapshots carry `app` (nil: the
    /// clock's own).
    public static func thin(_ noteID: UUID, mode: CompactionMode, vault: Vault, clock: DeviceClock, cache: SummaryCache?,
                            app: String? = nil, coordinated: Bool, files: any FileCoordinating = UncoordinatedFiles(),
                            verify: (@Sendable () throws -> Void)?,
                            dryRun: Bool, now: Date = Date(), perf: any PerfSink = NoPerfSink(),
                            isOpen: (@Sendable () async -> Bool)? = nil) async throws -> PreparedCompaction {
        let interval = perf.begin("thin.note")
        var stage = "metadata"
        defer { perf.end(interval, "note=\(String(noteID.uuidString.lowercased().prefix(8))) \(stage)") }
        let app = app ?? clock.app
        let empty = PreparedCompaction.nothing(noteID)
        let folder = coordinated ? URL(fileURLWithPath: vault.noteURL(noteID).path, isDirectory: true) : nil
        // 1. Metadata only.
        let loaded: LoadedNote? = try await Task.detached(priority: .utility) { () throws -> LoadedNote? in
            let names = try vault.revisionNames(of: noteID)
            if Vault.cachedCompactionVerdict(noteID, revisions: names, mode: mode, now: now, cache: cache) == false {
                return nil
            }
            return try files.coordinatedRead(coordinated ? vault.url : nil) { () throws -> LoadedNote? in
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
        if let isOpen, await isOpen() { throw ThinningSkippedOpen() }
        return try await Task.detached(priority: .utility) {
            let prepared = try vault.prepare(plan)
            if !dryRun, !plan.isEmpty {
                try files.coordinatedWrite(folder) {
                    try verify?()
                    try vault.execute(prepared)
                }
            }
            return prepared.withoutData
        }.value
    }
}
