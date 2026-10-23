import ArgumentParser
import Foundation
import Sempere

struct NotesHistory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List a note's restore points: one per revision, oldest first.",
        discussion: """
            Each row is a revision the note can be viewed at (`export --at`) or restored to
            (`notes restore --to`): kind, wall time, device, app and the revision name. Checkpoints
            (versions saved with `notes checkpoint` or the app's Save Version) are marked with their
            name. Revisions deleted by compaction are not restore points; a point marked "incomplete"
            cannot be rebuilt because revisions before it were compacted away or are unreadable.
            With --sessions the points are grouped as a history view shows them (format.md §5.8.2):
            each checkpoint on its own, and the autosaves between checkpoints in editing sessions
            (a new session when the note was closed and reopened, after a gap of 10 minutes or more,
            or when another device wrote). In --json every point says which group it is in.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Flag(name: .long, help: "Group the points into checkpoints and editing sessions.")
    var sessions = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Point: Encodable {
        var revision: String; var kind: String; var hlc: String; var device: String; var seq: Int
        var wall: Date; var app: String; var complete: Bool
        /// True for a checkpoint (format.md §5.8.1).
        var checkpoint: Bool
        /// The checkpoint's name, if it has one.
        var name: String?
        /// The editing-session id the revision carries, if any (format.md §5.8.2).
        var session: String?
        /// Index of the point's group in `notes history --sessions --json`.
        var group: Int
    }

    struct Group: Encodable {
        /// `checkpoint` or `session`.
        var type: String
        var device: String
        var session: String?
        /// The checkpoint's name (checkpoints only).
        var name: String?
        var start: Date
        var end: Date
        /// Number of restore points (saves) in the group.
        var saves: Int
        /// The newest point's revision: the one thinning keeps.
        var newest: String
        var points: [Point]
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let loaded = try vault.loadNote(id, detail: .withoutStrokePoints)   // restore points need no geometry
        let points = loaded.restorePoints
        if !loaded.failures.isEmpty {
            printError("warning: \(loaded.failures.count) unreadable revision(s) are not listed (see `notes show`)")
        }
        let groups = NoteHistory.groups(points)
        var groupOf: [RevisionName: Int] = [:]
        for (i, g) in groups.enumerated() { for p in g.points { groupOf[p.name] = i } }
        func json(_ p: RestorePoint) -> Point {
            Point(revision: p.name.filename, kind: p.kind.rawValue, hlc: p.hlc.description, device: p.device.rawValue,
                  seq: p.name.seq, wall: p.wall, app: p.app, complete: p.complete, checkpoint: p.isCheckpoint,
                  name: p.checkpoint?.name, session: p.session, group: groupOf[p.name] ?? 0)
        }
        if output.json {
            if sessions {
                try output.emitJSON(groups.map { g -> Group in
                    let first = g.points[0]
                    let isCheckpoint: Bool
                    if case .checkpoint = g { isCheckpoint = true } else { isCheckpoint = false }
                    return Group(type: isCheckpoint ? "checkpoint" : "session", device: first.device.rawValue,
                                 session: first.session, name: isCheckpoint ? first.checkpoint?.name : nil,
                                 start: first.wall, end: g.newest.wall, saves: g.points.count,
                                 newest: g.newest.name.filename, points: g.points.map(json))
                })
            } else {
                try output.emitJSON(points.map(json))
            }
            return
        }
        if points.isEmpty { output.info("No restore points."); return }
        func mark(_ p: RestorePoint) -> String {
            var s = p.name.filename
            if let c = p.checkpoint { s += "  (checkpoint" + (c.name.map { ": \($0)" } ?? "") + ")" }
            if !p.complete { s += "  (incomplete)" }
            return s
        }
        if sessions {
            var rows = output.quiet ? [] : [["GROUP", "FROM", "TO", "DEVICE", "SAVES", "NEWEST"]]
            for g in groups {
                let first = g.points[0]
                let label: String
                if case .checkpoint = g { label = "checkpoint" } else { label = "session" }
                rows.append([label, Format.local(first.wall), Format.local(g.newest.wall), first.device.rawValue,
                             "\(g.points.count)", mark(g.newest)])
            }
            print(Format.table(rows))
            return
        }
        var rows = output.quiet ? [] : [["KIND", "WALL", "DEVICE", "APP", "REVISION"]]
        for p in points {
            rows.append([p.kind.rawValue, Format.local(p.wall), p.device.rawValue, p.app, mark(p)])
        }
        print(Format.table(rows))
    }
}

struct NotesCheckpoint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkpoint",
        abstract: "Save the note as it is now as a named version (a checkpoint).",
        discussion: """
            Writes one delta with no ops marked as a checkpoint (format.md §5.8.1). Checkpoints are
            listed by `notes history`, can be restored with `notes restore --to`, and are never
            deleted by `compact`. The name is optional (trimmed, at most 200 characters). Device id
            and clock as for `sempere snapshot`.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Option(name: .long, help: ArgumentHelp("The version's name.", valueName: "text"))
    var name: String?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let rev = try vault.checkpoint(id, name: name, deviceState: DeviceState.defaultURL(), app: appName)
        let noteName = id.uuidString.lowercased()
        if output.json {
            struct Out: Encodable { var note: String; var file: String; var name: String?; var device: String }
            try output.emitJSON(Out(note: noteName, file: rev.name.filename, name: rev.checkpoint?.name,
                                    device: rev.device.rawValue))
        } else {
            output.info("Saved version\(rev.checkpoint?.name.map { " \"\($0)\"" } ?? "") of \(noteName): \(rev.name.filename)")
        }
    }
}

struct NotesRestore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a note to an earlier revision by writing one new delta.",
        discussion: """
            History is never rewritten: the new delta removes pages and strokes that did not exist
            at the restore point, re-adds those removed since under new ids (with `parent` naming the
            old id) and sets title, tags, notebook, paper, page size, page order and recognition back.
            REVISION is a name from `notes history`, with or without its `.delta.age` /
            `.snapshot.age` suffix, or a unique prefix of 6 or more characters. Nothing is written
            when the note already matches, or with --dry-run. The device id and clock come from
            $XDG_STATE_HOME/sempere/device.json, as for `snapshot`.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Option(name: .long, help: ArgumentHelp("The revision to restore to.", valueName: "revision"))
    var to: String

    @Flag(name: .customLong("dry-run"), help: "Only say what would change.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let point = try NoteHistory.resolve(to, among: try vault.revisionNames(of: id))
        let stateURL = DeviceState.defaultURL()
        var device = try DeviceState.loadOrCreate(at: stateURL)
        var clock = device.clock
        let result = try vault.restore(note: id, toRevision: point, device: device.device, clock: &clock,
                                       wall: Date(), app: appName, dryRun: dryRun)
        if result.written {
            device.clock = clock
            try device.save(to: stateURL)
        }
        let noteName = id.uuidString.lowercased()
        if output.json {
            struct Out: Encodable {
                var note: String; var to: String; var dryRun: Bool; var changed: Bool; var file: String?
                var changes: RestoreSummary
            }
            try output.emitJSON(Out(note: noteName, to: point.filename, dryRun: dryRun, changed: result.delta != nil,
                                    file: result.written ? result.delta?.name.filename : nil, changes: result.summary))
            return
        }
        guard result.delta != nil else {
            output.info("\(noteName) already matches \(point.filename); nothing to write.")
            return
        }
        let s = result.summary
        var parts: [String] = []
        if s.pagesRemoved > 0 { parts.append("remove \(s.pagesRemoved) page(s)") }
        if s.pagesRestored > 0 { parts.append("re-add \(s.pagesRestored) page(s)") }
        if s.strokesRemoved > 0 { parts.append("remove \(s.strokesRemoved) stroke(s)") }
        if s.strokesRestored > 0 { parts.append("re-add \(s.strokesRestored) stroke(s)") }
        if s.pageOrderChanges > 0 { parts.append("reorder \(s.pageOrderChanges) page(s)") }
        if s.recognitionChanges > 0 { parts.append("reset recognition on \(s.recognitionChanges) page(s)") }
        if s.pagePaperChanges > 0 { parts.append("reset paper on \(s.pagePaperChanges) page(s)") }
        if s.itemsRemoved > 0 { parts.append("remove \(s.itemsRemoved) item(s)") }
        if s.itemsRestored > 0 { parts.append("re-add \(s.itemsRestored) item(s)") }
        if s.itemChanges > 0 { parts.append("set back \(s.itemChanges) item(s)") }
        if s.recordingsRemoved > 0 { parts.append("remove \(s.recordingsRemoved) recording(s)") }
        if s.recordingsRestored > 0 { parts.append("re-add \(s.recordingsRestored) recording(s)") }
        if s.recordingChanges > 0 { parts.append("set back \(s.recordingChanges) recording(s)") }
        if !s.metaFields.isEmpty { parts.append("set \(s.metaFields.joined(separator: ", "))") }
        if let d = s.deleted { parts.append(d ? "delete the note" : "undelete the note") }
        let what = parts.joined(separator: "; ")
        if dryRun {
            print("would restore \(noteName) to \(point.filename): \(what)")
        } else {
            print("restored \(noteName) to \(point.filename): \(what)")
            output.info("Wrote \(noteName)/\(result.delta?.name.filename ?? "")")
        }
    }
}
