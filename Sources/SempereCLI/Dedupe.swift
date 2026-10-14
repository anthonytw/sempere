import ArgumentParser
import Foundation
import Sempere

// MARK: - notes dedupe

struct NotesDedupe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dedupe",
        abstract: "Find and remove strokes left over by concurrent edits of the same stroke.",
        discussion: """
            When two devices slice, move or recolour the same stroke without seeing each other's edit,
            readers keep the later edit and hide the other one's strokes (format.md §5.6.1). This
            command lists, per note, the strokes so hidden that revisions still add ("superseded"),
            and live strokes that duplicate others descending from the same stroke, which the merge
            cannot resolve ("duplicates": a stroke brought back by undo while another device sliced
            it). Unless --dry-run, it writes one delta per note that removes both: superseded strokes
            are already hidden, removing them makes the revisions say what every reader shows; of
            duplicates, the descendants of the latest edit stay. Device id and
            clock as for `sempere snapshot`. With --all, a note that cannot be read is reported on
            stderr, the others are still processed, and the exit code is 1.
            """
    )

    @Argument(help: ArgumentHelp("Note ids or titles (or use --all).", valueName: "id|title"))
    var notes: [String] = []

    @Flag(name: .long, help: "Every note of the vault.")
    var all = false

    @Flag(name: .customLong("dry-run"), help: "Only list what would be removed (a check).")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if all == !notes.isEmpty { throw ValidationError("Name one or more notes, or give --all.") }
    }

    struct Item: Encodable {
        struct Ref: Encodable { var page: String; var stroke: String }
        var note: String
        var superseded: [Ref]
        var duplicates: [Ref]
        /// The delta written; null on a dry run or when nothing was found.
        var file: String?
    }

    func run() throws {
        let vault = try access.openVault(.required)
        if all { try vault.requireCompleteCopy() }
        let ids = all ? try vault.noteIDs() : try notes.map { try vault.resolveNote($0) }
        var items: [Item] = []
        var failures = 0
        var readOnly: String?
        for id in ids {
            let name = id.uuidString.lowercased()
            do {
                let conflicts: StrokeConflicts
                var file: String?
                if dryRun {
                    conflicts = try vault.strokeConflicts(of: id)
                } else {
                    let r = try vault.dedupeStrokes(of: id, deviceState: DeviceState.defaultURL(), app: appName)
                    conflicts = r.conflicts
                    file = r.revision?.name.filename
                }
                func refs(_ l: [StrokeRef]) -> [Item.Ref] {
                    l.map { Item.Ref(page: $0.page.uuidString.lowercased(), stroke: $0.stroke.uuidString.lowercased()) }
                }
                items.append(Item(note: name, superseded: refs(conflicts.superseded),
                                  duplicates: refs(conflicts.duplicates), file: file))
            } catch {
                // A note named explicitly fails the command as any single-note command does.
                guard all else { throw error }
                failures += 1
                let e = CLIError.from(error)
                if case .readOnly(let m) = e { readOnly = m }
                printError("\(name): \(e.message)")
            }
        }
        if output.json {
            try output.emitJSON(items)
        } else {
            let found = items.filter { !$0.superseded.isEmpty || !$0.duplicates.isEmpty }
            for i in found {
                let what = "\(i.superseded.count) superseded, \(i.duplicates.count) duplicate stroke(s)"
                if let f = i.file {
                    print("removed \(what) from \(i.note) (\(i.note)/\(f))")
                } else {
                    print("\(dryRun ? "would remove" : "found") \(what) in \(i.note)")
                }
            }
            if found.isEmpty { output.info("No leftover strokes in \(items.count) note(s).") }
        }
        if let readOnly { throw CLIError.readOnly(readOnly) }
        if failures > 0 { throw CLIError.failure("\(failures) note(s) could not be checked") }
    }
}
