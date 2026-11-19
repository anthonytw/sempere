import ArgumentParser
import Foundation
import Sempere

// `sempere tools` (docs/design/1.3-custom-tools.md §3.6): the saved tools of the palette, which live in the vault's
// shared settings (settings.age, one slot per preset). The CLI is not a device: it edits the vault's file, has no
// local list, and records no device type in `$meta`. The logic is the package's (`SavedTool`, `SavedToolList`).

struct ToolsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "The palette's saved tools (ink, color, width, opacity): list, add, edit, remove, move, export, import.",
        discussion: """
            Saved tools are shared settings (docs/settings-sync.md): devices with Settings ▸ Sync Settings with This
            Vault on show them in their palettes. TOOL is an id, an id prefix (4 or more characters) or an exact name;
            an ambiguous name is an error naming the ids. At most 64 tools; names are 1 to 40 characters.

            Exit codes: 3 for a value that is not valid, 6 for an untrusted device list, 7 for a read-only vault or
            settings that need a newer sempere.
            """,
        subcommands: [ToolsList.self, ToolsAdd.self, ToolsEdit.self, ToolsRemove.self, ToolsMove.self, ToolsExport.self,
                      ToolsImport.self]
    )
}

enum ToolsText {
    struct Row: Encodable {
        var id: String
        var name: String
        var ink: String
        var color: String
        var width: Double
        var opacity: Double
        var at: Int64
        var order: Int

        init(_ t: SavedTool, order: Int) {
            id = t.id; name = t.name; ink = t.ink.rawValue; color = SavedTool.hex(t.color); width = t.width
            opacity = t.opacity; at = t.at; self.order = order
        }
    }

    static func rows(_ list: SavedToolList) -> [Row] { list.tools.enumerated().map { Row($1, order: $0 + 1) } }

    static func ink(_ text: String) throws -> InkTool {
        guard let ink = InkTool.allCases.first(where: { $0.rawValue.lowercased() == text.lowercased() }) else {
            throw CLIError.usage("'\(SharedSettings.printable(text))' is not an ink: "
                + InkTool.allCases.map(\.rawValue).sorted().joined(separator: ", "))
        }
        return ink
    }

    static func color(_ text: String) throws -> Color {
        guard let c = SavedTool.color(fromHex: text) else { throw CLIError.usage("the color is #RRGGBB, e.g. '#D32F2F'") }
        return c
    }

    /// A `SavedToolError` as a CLI error: an invalid value is exit 3.
    static func map(_ error: Error) -> Error {
        switch error as? SavedToolError {
        case .invalid?, .tooMany?: return CLIError.unhealthy("\(error)")
        case .badPosition?: return CLIError.usage("\(error)")
        case .notFound?, .ambiguous?: return CLIError.failure("\(error)")
        case nil: return error
        }
    }

    static func read(_ vault: Vault) throws -> (SharedSettings, SavedToolList) {
        let s = try SettingsText.read(vault)
        return (s, SavedToolList(settings: s))
    }

    /// Runs `change` on the vault's settings and writes them (merged with what other devices wrote), and returns the
    /// list as written.
    @discardableResult
    static func update(_ vault: Vault, _ change: (inout SharedSettings, SavedToolList) throws -> Void) throws -> SavedToolList {
        do {
            let written = try vault.updateSharedSettings { s in
                try change(&s, SavedToolList(settings: s))
            }
            return SavedToolList(settings: written)
        } catch {
            throw map(error)
        }
    }

    static func describe(_ t: SavedTool) -> String {
        "\(t.name) (\(t.id.prefix(8)): \(t.ink.rawValue), \(SavedTool.hex(t.color)), width \(SavedTool.number(t.width)), "
            + "opacity \(SavedTool.number(t.opacity)))"
    }
}

// MARK: - list

struct ToolsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The saved tools, in palette order.")

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable { var tools: [ToolsText.Row]; var hidden: Int; var warnings: [String] }

    func run() throws {
        let vault = try access.openVault(.required)
        let list = try ToolsText.read(vault).1
        for w in list.warnings { printError("warning: \(w)") }
        if output.json {
            try output.emitJSON(Out(tools: ToolsText.rows(list), hidden: list.hiddenCount, warnings: list.warnings))
            return
        }
        var table = [["#", "ID", "NAME", "INK", "COLOR", "WIDTH", "OPACITY"]]
        table += ToolsText.rows(list).map { [String($0.order), $0.id, $0.name, $0.ink, $0.color, SavedTool.number($0.width),
                                              SavedTool.number($0.opacity)] }
        print(Format.table(table))
        if list.hiddenCount > 0 { output.info("\(list.hiddenCount) more kept in the file and not shown (newer inks, invalid or beyond 64)") }
    }
}

// MARK: - add

struct ToolsAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Save a new tool (it goes last).")

    @Argument(help: "The name, 1 to 40 characters.") var name: String
    @Option(name: .long, help: ArgumentHelp("pen, monoline, fountainPen, marker, pencil, watercolor or crayon.", valueName: "ink"))
    var ink: String
    @Option(name: .long, help: ArgumentHelp("#RRGGBB.", valueName: "color")) var color: String
    @Option(name: .long, help: ArgumentHelp("In the palette's width units (inside the ink's range).", valueName: "width"))
    var width: Double
    @Option(name: .long, help: ArgumentHelp("0.05 to 1 (default 1).", valueName: "opacity")) var opacity: Double = 1
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let inkTool = try ToolsText.ink(ink), c = try ToolsText.color(color)
        guard let clean = SavedTool.cleanName(name) else {
            throw CLIError.unhealthy("invalid saved tool: the name must be 1 to \(SavedTool.maxNameLength) characters with no control characters")
        }
        let vault = try access.openVault(.required)
        let tool = SavedTool(name: clean, ink: inkTool, color: c, width: width, opacity: opacity, at: SharedSettings.millis(Date()))
        try ToolsText.update(vault) { s, _ in try SavedToolList.add(tool, to: &s) }
        if output.json { try output.emitJSON(ToolsText.Row(tool, order: 0)) } else { output.info("added \(ToolsText.describe(tool))") }
    }
}

// MARK: - edit

struct ToolsEdit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change a saved tool (only the options given).")

    @Argument(help: "The tool: an id, an id prefix or an exact name.") var tool: String
    @Option(name: .long, help: "A new name.") var name: String?
    @Option(name: .long, help: "A new ink.") var ink: String?
    @Option(name: .long, help: "A new color, #RRGGBB.") var color: String?
    @Option(name: .long, help: "A new width.") var width: Double?
    @Option(name: .long, help: "A new opacity, 0.05 to 1.") var opacity: Double?
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard name != nil || ink != nil || color != nil || width != nil || opacity != nil else {
            throw CLIError.usage("nothing to change: give --name, --ink, --color, --width or --opacity")
        }
        let newInk = try ink.map(ToolsText.ink), newColor = try color.map(ToolsText.color)
        let vault = try access.openVault(.required)
        var changed: SavedTool?
        try ToolsText.update(vault) { s, list in
            var t = try list.resolve(tool)
            if let name {
                guard let clean = SavedTool.cleanName(name) else {
                    throw SavedToolError.invalid("the name must be 1 to \(SavedTool.maxNameLength) characters with no control characters")
                }
                t.name = clean
            }
            if let newInk { t.ink = newInk }
            if let newColor { t.color = newColor }
            if let width { t.width = width }
            if let opacity { t.opacity = opacity }
            try SavedToolList.update(t, in: &s)
            changed = t
        }
        guard let changed else { return }
        if output.json { try output.emitJSON(ToolsText.Row(changed, order: 0)) } else { output.info("changed \(ToolsText.describe(changed))") }
    }
}

// MARK: - remove

struct ToolsRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Delete a saved tool.",
        discussion: "Recorded as a reset of its slot, so a device that still holds the tool does not bring it back.")

    @Argument(help: "The tool: an id, an id prefix or an exact name.") var tool: String
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable { var removed: String; var name: String }

    func run() throws {
        let vault = try access.openVault(.required)
        var removed: SavedTool?
        try ToolsText.update(vault) { s, list in
            let t = try list.resolve(tool)
            try SavedToolList.remove(id: t.id, from: &s)
            removed = t
        }
        guard let removed else { return }
        if output.json { try output.emitJSON(Out(removed: removed.id, name: removed.name)) } else { output.info("removed \(ToolsText.describe(removed))") }
    }
}

// MARK: - move

struct ToolsMove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Change the order of a saved tool.")

    @Argument(help: "The tool to move.") var tool: String
    @Option(name: .long, help: ArgumentHelp("Move to this 1-based position.", valueName: "n")) var to: Int?
    @Option(name: .long, help: ArgumentHelp("Move before this tool.", valueName: "tool")) var before: String?
    @Option(name: .long, help: ArgumentHelp("Move after this tool.", valueName: "tool")) var after: String?
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard [to != nil, before != nil, after != nil].filter({ $0 }).count == 1 else {
            throw ValidationError("give exactly one of --to, --before, --after")
        }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let list = try ToolsText.update(vault) { s, list in
            let t = try list.resolve(tool)
            let destination: SavedToolList.Destination
            if let to { destination = .position(to) }
            else if let before { destination = .before(try list.resolve(before).id) }
            else { destination = .after(try list.resolve(after ?? "").id) }
            try SavedToolList.move(id: t.id, to: destination, in: &s)
        }
        if output.json { try output.emitJSON(ToolsList.Out(tools: ToolsText.rows(list), hidden: list.hiddenCount, warnings: list.warnings)) }
        else { output.info("moved; order: " + list.tools.map(\.name).joined(separator: ", ")) }
    }
}

// MARK: - export / import

struct ToolsExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Write the saved tools as a sempere-tools/1 file (no ids).",
        discussion: "To the standard output without --out. A file is never overwritten.")

    @Option(name: .long, help: ArgumentHelp("The file to write.", valueName: "file")) var out: String?
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Result: Encodable { var file: String?; var count: Int }

    func run() throws {
        let vault = try access.openVault(.required)
        let list = try ToolsText.read(vault).1
        let data = try SavedToolFile.encode(list)
        guard let out else {
            FileHandle.standardOutput.write(data)
            return
        }
        guard !FileManager.default.fileExists(atPath: out) else { throw CLIError.failure("\(out) exists; not overwriting") }
        try writePrivateFile(data, to: URL(fileURLWithPath: out))
        if output.json { try output.emitJSON(Result(file: out, count: list.tools.count)) } else { output.info("wrote \(list.tools.count) tools to \(out)") }
    }
}

struct ToolsImport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Add the tools of a sempere-tools/1 file, with new ids.",
        discussion: """
            Entries that are not valid are skipped and reported. With --replace the vault's tools are removed first,
            which needs --yes. More than 64 tools altogether are refused (the entries that do not fit are skipped).
            """)

    @Argument(help: "The file.") var file: String
    @Flag(name: .long, help: "Remove the vault's saved tools first.") var replace = false
    @Flag(name: .long, help: "Confirm --replace.") var yes = false
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Result: Encodable { var added: Int; var removed: Int; var skipped: [String] }

    func run() throws {
        guard !replace || yes else { throw CLIError.failure("--replace removes the vault's saved tools: add --yes to confirm") }
        let data = try BoundedRead.contents(of: URL(fileURLWithPath: file), maxBytes: SavedToolFile.maxBytes)
        let parsed: SavedToolFile.Parsed
        do { parsed = try SavedToolFile.parse(data) } catch { throw ToolsText.map(error) }
        let vault = try access.openVault(.required)
        var skipped = parsed.skipped, added = 0, removed = 0
        try ToolsText.update(vault) { s, list in
            let now = Date()
            if replace {
                for t in list.tools { try SavedToolList.remove(id: t.id, from: &s, now: now) }
                removed = list.tools.count
            }
            var order = replace ? [] : list.tools.map(\.id)
            for t in parsed.tools {
                do { try SavedToolList.add(t, to: &s, now: now) } catch SavedToolError.tooMany {
                    skipped.append("'\(t.name)': at most \(SavedTool.maxTools) saved tools")
                    continue
                }
                order.append(t.id)
                added += 1
            }
            if added > 0 { try SavedToolList.writeOrder(order, to: &s, now: now) }
        }
        for line in skipped { printError("skipped: \(line)") }
        if output.json { try output.emitJSON(Result(added: added, removed: removed, skipped: skipped)) }
        else { output.info("added \(added) saved tools" + (replace ? ", removed \(removed)" : "")) }
    }
}
