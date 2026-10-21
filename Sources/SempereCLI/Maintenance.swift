import ArgumentParser
import Foundation
import Sempere

/// The `app` stamped into every delta the CLI writes: "sempere-cli/" plus the CLI's one version constant.
let appName = "sempere-cli/\(sempereVersion)"

struct CompactCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compact",
        abstract: "Delete revisions that a snapshot makes redundant, or thin old autosaves.",
        discussion: """
            Without --thin-older-than: deletes revisions past the retention window that a snapshot
            covers (format.md §5.3), writing a snapshot first when needed. With --thin-older-than:
            in revisions older than that, keeps every checkpoint and the newest autosave of each
            editing session and deletes the rest (format.md §5.8.4). With --thin-all: the same with no
            age window and no session ends, so every autosave goes, however recent, except the
            note's newest revision (imports are checkpoints and stay). Thinning prints the rule it applies first. Either way checkpoints are never
            deleted, and every checkpoint (and when thinning, every kept autosave and every newer
            revision) stays a restore point with the same content: positioned snapshots are written
            for them first. Device id and clock as for `sempere snapshot`. With --dry-run nothing is
            written or deleted; the output says what would be, with the bytes freed and added.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title (or use --all).", valueName: "id|title"))
    var note: String?

    @Flag(name: .long, help: "Compact every note.")
    var all = false

    @Option(name: .long, help: ArgumentHelp("Keep revisions younger than this many days (default 30).", valueName: "days"))
    var retention: Double?

    @Option(name: .customLong("thin-older-than"),
            help: ArgumentHelp("Thin revisions older than this: days, as `30d` or `30`, or `never`.", valueName: "age"))
    var thinOlderThan: String?

    @Flag(name: .customLong("thin-all"),
          help: "Thin everything except checkpoints: ignore the age window; keep every checkpoint and the note's newest revision, no session ends.")
    var thinAll = false

    @Flag(name: .customLong("dry-run"), help: "Only list what would be written and deleted.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var cache: CacheOptions

    /// Days from `30d`, `30` or `never` (nil); nil for anything else is an error.
    static func parseAge(_ text: String) throws -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "never" { return nil }
        let digits = t.hasSuffix("d") ? String(t.dropLast()) : t
        guard let days = Double(digits), days.isFinite, days > 0, days <= 100_000 else {
            throw ValidationError("--thin-older-than takes a number of days, like 30d, or never")
        }
        return days
    }

    func validate() throws {
        guard all != (note != nil) else { throw ValidationError("give exactly one of a note (id or title) and --all") }
        if let retention, retention < 0 || !retention.isFinite {
            throw ValidationError("--retention must not be negative")
        }
        if [thinOlderThan != nil, retention != nil, thinAll].filter({ $0 }).count > 1 {
            throw ValidationError("--retention, --thin-older-than and --thin-all are different modes; give one")
        }
        if let thinOlderThan { _ = try Self.parseAge(thinOlderThan) }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        try vault.requireWritable()   // format.md §7.3: exit 7
        if note == nil { try vault.requireCompleteCopy() }
        let ids = try note.map { [try vault.resolveNote($0)] } ?? vault.noteIDs()
        let mode: CompactionMode
        var rule: ThinningRule?
        if thinAll {
            rule = .allButCheckpoints
            mode = ThinningRule.allButCheckpoints.mode
        } else if let thinOlderThan {
            guard let days = try Self.parseAge(thinOlderThan) else {
                if output.json { try output.emitJSON([Item]()) } else { output.info("Thinning is off (never); nothing to do.") }
                return
            }
            if days == days.rounded(), days >= 1, days < 1e6 { rule = .olderThan(days: Int(days)) }
            mode = .thin(olderThan: days * 86400)
        } else {
            mode = .retention((retention ?? CompactionPlanner.defaultRetention / 86400) * 86400)
        }
        let stateURL = DeviceState.defaultURL()
        // A dry run writes nothing, not even a first device state file.
        var state = dryRun && !FileManager.default.fileExists(atPath: stateURL.path)
            ? DeviceState(device: .random()) : try DeviceState.loadOrCreate(at: stateURL)
        var items: [Item] = []
        var failures = 0
        var readOnly: String?
        let now = Date()
        let summaries = cache.cache(for: vault)
        defer { if summaries?.hasChanges == true { try? summaries?.save() } }
        // Read, planned and carried out in parallel; notes whose revision metadata shows nothing to
        // delete are not read in full (the summary cache usually has that metadata).
        var clock = state.clock
        let prepared = vault.prepareCompactions(ids, mode: mode, now: now, device: vault.writerDevice ?? state.device, clock: &clock,
                                                app: appName, cache: summaries, execute: !dryRun)
        if !dryRun, clock != state.clock {
            state.clock = clock
            try state.save(to: stateURL)
        }
        for (id, result) in prepared {
            let name = id.uuidString.lowercased()
            do {
                let prepared = try result.get()
                let plan = prepared.plan
                items.append(Item(note: name, snapshotNeeded: !plan.snapshots.isEmpty,
                                  snapshot: dryRun ? nil : plan.snapshots.first?.name.filename,
                                  snapshots: plan.snapshots.map {
                                      Item.Snapshot(file: dryRun ? nil : $0.name.filename, asOf: $0.asOf?.description)
                                  },
                                  files: plan.deletions.map(\.filename), witnesses: plan.witnesses.map(\.filename),
                                  bytesDeleted: prepared.bytesDeleted, bytesAdded: prepared.bytesAdded))
            } catch {
                failures += 1
                let e = CLIError.from(error)
                if case .readOnly(let m) = e { readOnly = m }
                printError("\(name): \(e.message)")
            }
        }
        if let rule, !output.json { output.info("\(rule.title)\(dryRun ? " (dry run)" : ""). \(rule.explanation)") }
        if output.json {
            try output.emitJSON(items)
        } else {
            let total = items.reduce(0) { $0 + $1.files.count }
            for i in items {
                for s in i.snapshots {
                    let at = s.asOf.map { " (as of \($0))" } ?? ""
                    print(dryRun ? "would snapshot \(i.note)\(at)" : "snapshot \(i.note)/\(s.file ?? "")\(at)")
                }
                for f in i.files { print("\(dryRun ? "would delete" : "deleted") \(i.note)/\(f)") }
            }
            let freed = items.reduce(0) { $0 + $1.bytesDeleted }, added = items.reduce(0) { $0 + $1.bytesAdded }
            output.info("\(dryRun ? "Would delete" : "Deleted") \(total) file(s), \(Format.bytes(freed)); "
                        + "\(dryRun ? "would add" : "added") \(items.reduce(0) { $0 + $1.snapshots.count }) snapshot(s), \(Format.bytes(added)).")
        }
        // A note read on the way may have been newer (format.md §7.3).
        do { try vault.requireWritable() } catch { readOnly = readOnly ?? CLIError.from(error).message }
        if let readOnly { throw CLIError.readOnly(readOnly) }
        if failures > 0 { throw CLIError.failure("\(failures) note(s) could not be compacted") }
    }

    struct Item: Encodable {
        struct Snapshot: Encodable {
            /// The file written; nil on a dry run.
            var file: String?
            /// For a positioned snapshot, the revision it holds the note as of (format.md §5.8.3).
            var asOf: String?
        }
        var note: String
        /// At least one snapshot is (dry run) or was (real run) written first.
        var snapshotNeeded: Bool
        /// The first snapshot file written; nil on a dry run or when none was needed.
        var snapshot: String?
        var snapshots: [Snapshot]
        /// Revision files deleted (or that would be).
        var files: [String]
        /// Revisions kept only to keep a restore point complete (format.md §5.8.4 rule 3).
        var witnesses: [String]
        var bytesDeleted: Int
        var bytesAdded: Int
    }
}

/// Writes a snapshot of an already-loaded note with this machine's device id
/// and clock, and saves the clock. Returns the snapshot and the device state.
func takeSnapshot(_ vault: Vault, loaded: LoadedNote) throws -> (Revision, DeviceState) {
    let stateURL = DeviceState.defaultURL()
    var state = try DeviceState.loadOrCreate(at: stateURL)
    var clock = state.clock
    let snap = try vault.snapshot(loaded: loaded, device: vault.writerDevice ?? state.device, clock: &clock, wall: Date(), app: appName)
    state.clock = clock
    try state.save(to: stateURL)
    return (snap, state)
}

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Write a snapshot of a note (so older revisions can be compacted).",
        discussion: "The device id and clock come from $XDG_STATE_HOME/sempere/device.json (default ~/.local/state), created on first use."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let (snap, state) = try takeSnapshot(vault, loaded: try vault.loadNote(id))
        if output.json {
            struct Out: Encodable { var note: String; var file: String; var device: String }
            try output.emitJSON(Out(note: id.uuidString.lowercased(), file: snap.name.filename,
                                    device: (vault.writerDevice ?? state.device).rawValue))
        } else {
            output.info("Wrote \(id.uuidString.lowercased())/\(snap.name.filename)")
        }
    }
}
