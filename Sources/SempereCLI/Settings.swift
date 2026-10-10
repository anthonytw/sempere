import ArgumentParser
import Foundation
import Sempere

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// `sempere settings` (docs/settings-sync.md §7): the vault's shared settings
// file, settings.age (format.md §13). The CLI is not a device: it has no local
// overrides and records no device type in `$meta`.

struct SettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "The vault's shared settings (settings.age): list, get, set, reset, edit, validate.",
        discussion: """
            Devices with Settings ▸ Sync Settings with This Vault on follow these settings
            (docs/settings-sync.md). Keys are flat and dotted (editor.defaultPaper); a key may also have a
            value for one kind of device only, in a type block ([mac], [ipad], [iphone]): --type targets it.
            A device resolves a setting from its type block, then the top level, then the built-in default.

            The CLI has no device overrides: "Only on This Device" lives on each device, and wins there over
            anything set here. Writes merge per key with what other devices wrote (last writer wins), keep keys
            this version does not know, and record no device type. A vault whose settings need a newer sempere
            is refused (exit 7) and never rewritten.
            """,
        subcommands: [SettingsList.self, SettingsGet.self, SettingsSet.self, SettingsReset.self, SettingsEdit.self,
                      SettingsValidate.self, SettingsSchema.self]
    )
}

/// `--type mac|ipad|iphone`.
struct SettingsTypeOption: ParsableArguments {
    @Option(name: .customLong("type"),
            help: ArgumentHelp("A device type's block: mac, ipad or iphone (default: the top level).", valueName: "type"))
    var deviceType: String?

    func resolved() throws -> SettingsDeviceType? {
        guard let deviceType else { return nil }
        guard let t = SettingsDeviceType(rawValue: deviceType.lowercased()) else {
            throw CLIError.usage("--type is mac, ipad or iphone")
        }
        return t
    }
}

enum SettingsText {
    /// A value as compact JSON: `true`, `"isoDateTime"`, `{"kind":"grid"}`.
    static func show(_ value: JSONValue?) -> String {
        guard let value, let data = try? InkJSON.encoder().encode(value) else { return "(reset)" }
        return String(decoding: data, as: UTF8.self)
    }

    static func spec(_ key: String) throws -> SharedSettingSpec {
        guard let spec = SharedSettingsCatalog.spec(named: key) else {
            throw CLIError.usage("unknown setting '\(SharedSettings.printable(key))' (sempere settings list shows them)")
        }
        return spec
    }

    static func where_(_ block: SettingsDeviceType?) -> String { block.map { "[\($0.rawValue)]" } ?? "the top level" }

    static func usedBy(_ spec: SharedSettingSpec) -> String { spec.types?.map(\.rawValue).joined(separator: ",") ?? "all" }

    /// The vault's settings, migrated; empty when it has none.
    static func read(_ vault: Vault) throws -> SharedSettings {
        try vault.readSharedSettings() ?? SharedSettings()
    }
}

// MARK: - list

struct SettingsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Every known setting with its value, and where it comes from.",
        discussion: """
            Without --type: the top level (or the default). With --type: what a device of that type uses (its block,
            the top level, or the default). --all adds keys this version does not know and every type block.
            """
    )

    @OptionGroup var type: SettingsTypeOption
    @Flag(name: .long, help: "Also list unknown keys and the type blocks.") var all = false
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Row: Encodable {
        var key: String
        var value: JSONValue
        var source: String
        var defaultValue: JSONValue
        var usedBy: [String]
        var summary: String
    }

    struct Raw: Encodable {
        var key: String
        var block: String?
        var value: JSONValue?
        var known: Bool
    }

    struct Listing: Encodable {
        var schemaVersion: Int
        var minReaderVersion: Int
        var type: String?
        var settings: [Row]
        var others: [Raw]?
    }

    func run() throws {
        let deviceType = try type.resolved()
        let vault = try access.openVault(.required)
        let s = try SettingsText.read(vault)
        var rows: [Row] = []
        for spec in SharedSettingsCatalog.specs {
            if let deviceType, !spec.isUsed(by: deviceType) { continue }
            let r = s.resolve(spec, for: deviceType)
            for w in r.warnings { printError("warning: \(w)") }
            rows.append(Row(key: spec.name, value: r.value, source: r.source.rawValue, defaultValue: spec.defaultValue,
                            usedBy: spec.types?.map(\.rawValue) ?? ["mac", "ipad", "iphone"], summary: spec.summary))
        }
        var others: [Raw]?
        if all {
            others = s.slots.keys.sorted()
                .filter { $0.block != nil || SharedSettingsCatalog.spec(named: $0.key) == nil }
                .map { Raw(key: $0.key, block: $0.block, value: s.slots[$0]?.value,
                           known: SharedSettingsCatalog.spec(named: $0.key) != nil) }
        }
        if output.json {
            try output.emitJSON(Listing(schemaVersion: s.schemaVersion, minReaderVersion: s.minReaderVersion,
                                        type: deviceType?.rawValue, settings: rows, others: others))
            return
        }
        var table = [["KEY", "VALUE", "FROM", "USED BY"]]
        table += rows.map { [$0.key, SettingsText.show($0.value), $0.source, $0.usedBy.joined(separator: ",")] }
        print(Format.table(table))
        if let others, !others.isEmpty {
            print("")
            var t = [["BLOCK", "KEY", "VALUE", ""]]
            t += others.map { [$0.block.map { "[\($0)]" } ?? "-", SharedSettings.printable($0.key), SettingsText.show($0.value),
                               $0.known ? "" : "unknown"] }
            print(Format.table(t))
        }
    }
}

// MARK: - get

struct SettingsGet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "One setting's value (resolved for --type), as JSON.",
        discussion: "A key this version does not know prints its raw value at the top level (or in the --type block)."
    )

    @Argument(help: "The setting's key, e.g. editor.defaultPaper.") var key: String
    @OptionGroup var type: SettingsTypeOption
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable { var key: String; var value: JSONValue?; var source: String }

    func run() throws {
        let deviceType = try type.resolved()
        let vault = try access.openVault(.required)
        let s = try SettingsText.read(vault)
        let out: Out
        if let spec = SharedSettingsCatalog.spec(named: key) {
            let r = s.resolve(spec, for: deviceType)
            for w in r.warnings { printError("warning: \(w)") }
            out = Out(key: key, value: r.value, source: r.source.rawValue)
        } else {
            let slot = SettingSlotKey(key, block: deviceType?.rawValue)
            guard let v = s.value(slot) else {
                throw CLIError.failure("'\(SharedSettings.printable(key))' is not a known setting and is not set")
            }
            out = Out(key: key, value: v, source: deviceType == nil ? "top" : "block")
        }
        if output.json { try output.emitJSON(out) } else { print(SettingsText.show(out.value)) }
    }
}

// MARK: - set / reset

struct SettingsSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a setting for every device (or, with --type, for one kind of device).",
        discussion: """
            VALUE: true/false/on/off for switches, a number, a name, a notebook path, a title pattern, a paper kind
            (ruled, grid, …) or a paper JSON object, null for the device's language. Unknown keys are refused.
            """
    )

    @Argument(help: "The setting's key.") var key: String
    @Argument(help: "The value.") var value: String
    @OptionGroup var type: SettingsTypeOption
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable { var key: String; var value: JSONValue?; var block: String? }

    func run() throws {
        let deviceType = try type.resolved()
        let spec = try SettingsText.spec(key)
        guard let parsed = spec.parse(value) else {
            throw CLIError.usage("'\(SharedSettings.printable(value))' is not a value of \(key): \(spec.valuesDescription)")
        }
        let vault = try access.openVault(.required)
        try vault.updateSharedSettings { try $0.write(spec, parsed, block: deviceType?.rawValue, type: nil, now: Date()) }
        if output.json {
            try output.emitJSON(Out(key: key, value: parsed, block: deviceType?.rawValue))
        } else {
            output.info("\(key) = \(SettingsText.show(parsed)) (\(SettingsText.where_(deviceType)))")
        }
    }
}

struct SettingsReset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset a setting to its default (with --type: remove the type block's value, so the top level applies).",
        discussion: "Recorded as a reset, so devices that still hold the old value do not bring it back."
    )

    @Argument(help: "The setting's key.") var key: String
    @OptionGroup var type: SettingsTypeOption
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let deviceType = try type.resolved()
        let vault = try access.openVault(.required)
        let spec = SharedSettingsCatalog.spec(named: key)
        guard spec != nil || SharedSettingKeyCheck.isSettingKey(key) else {
            throw CLIError.usage("'\(SharedSettings.printable(key))' is not a setting key")
        }
        try vault.updateSharedSettings { s in
            if let spec {
                try s.write(spec, nil, block: deviceType?.rawValue, type: nil, now: Date())
            } else {
                try s.set(SettingSlotKey(key, block: deviceType?.rawValue), to: nil, type: nil, now: Date())
            }
        }
        if output.json {
            try output.emitJSON(SettingsSet.Out(key: key, value: nil, block: deviceType?.rawValue))
        } else {
            output.info("\(key) reset (\(SettingsText.where_(deviceType)))")
        }
    }
}

enum SharedSettingKeyCheck {
    /// A top-level member name that is a setting (not `$…` or `[…]`), at most 256 bytes.
    static func isSettingKey(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 256 && !s.hasPrefix("$") && !s.hasPrefix("[")
    }
}

// MARK: - edit

struct SettingsEdit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit the settings as JSON in $VISUAL or $EDITOR (else vi).",
        discussion: """
            The decrypted settings (without $meta) go to a private temporary file (mode 0600 in a 0700 folder,
            deleted afterwards). On save the result is validated: an invalid file (not JSON, an invalid value of a
            known key, a missing version) is refused and nothing is written. Each changed key is then recorded in
            $meta and merged with what other devices wrote. $schemaVersion and $minReaderVersion cannot be changed.
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable { var changed: [String] }

    func run() throws {
        let vault = try access.openVault(.required)
        try vault.requireWritable()
        let before = try SettingsText.read(vault)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-settings-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let original = try before.encoded(includingMeta: false)
        try writePrivateFile(original, to: file)
        try Self.runEditor(on: file)
        let edited = try BoundedRead.contents(of: file, maxBytes: SharedSettings.maxJSONBytes)
        let after = try Self.check(edited)
        let changes = Self.changes(from: before, to: after)
        if changes.slots.isEmpty && changes.extra == before.extra {
            if output.json { try output.emitJSON(Out(changed: [])) } else { output.info("no changes") }
            return
        }
        try vault.updateSharedSettings { s in
            let now = Date()
            for (slot, value) in changes.slots {
                if let spec = SharedSettingsCatalog.spec(named: slot.key) {
                    try s.write(spec, value, block: slot.block, type: nil, now: now)
                } else {
                    try s.set(slot, to: value, type: nil, now: now)
                }
            }
            s.extra = changes.extra
        }
        let names = changes.slots.keys.sorted().map(\.description)
        if output.json { try output.emitJSON(Out(changed: names)) } else { output.info("changed: \(names.joined(separator: ", "))") }
    }

    /// Runs `$VISUAL`, `$EDITOR` or `vi` on `file` through `/bin/sh` (so an
    /// editor with arguments, `code --wait`, works) with the terminal attached.
    static func runEditor(on file: URL) throws {
        let editor = [Env.vars["VISUAL"], Env.vars["EDITOR"]].compactMap { $0 }.first { !$0.isEmpty } ?? "vi"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", editor + " \"$1\"", "sh", file.path]
        do { try p.run() } catch { throw CLIError.failure("cannot start the editor (\(editor)): \(error.localizedDescription)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw CLIError.failure("the editor exited with status \(p.terminationStatus); nothing was written")
        }
    }

    /// The edited file, validated: refused (nothing written) when it is not a
    /// settings object or a known key has an invalid value.
    static func check(_ data: Data) throws -> SharedSettings {
        let decoded: SharedSettings.Decoded
        do { decoded = try SharedSettings.decode(data) } catch {
            throw CLIError.failure("the edited settings are not a JSON object; nothing was written")
        }
        if decoded.settings.slots.values.contains(where: { $0.meta != nil }) {
            throw CLIError.failure("the edited settings hold $meta, which the CLI keeps itself; nothing was written")
        }
        let errors = SharedSettingsCatalog.issues(in: decoded).filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw CLIError.failure("the edited settings are invalid; nothing was written: "
                + errors.map(\.description).joined(separator: "; "))
        }
        return decoded.settings
    }

    /// The slots whose value changed (nil: removed, a reset), and the `$…` members after the edit.
    static func changes(from before: SharedSettings, to after: SharedSettings)
        -> (slots: [SettingSlotKey: JSONValue?], extra: [String: JSONValue]) {
        var out: [SettingSlotKey: JSONValue?] = [:]
        let keys = Set(before.slots.keys.filter { before.value($0) != nil }).union(after.slots.keys)
        for k in keys where before.value(k) != after.value(k) { out[k] = .some(after.value(k)) }
        return (out, after.extra)
    }
}

// MARK: - validate / schema

struct SettingsValidate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Check the settings file against its schema (docs/settings.schema.json).",
        discussion: """
            Invalid values of known keys, malformed $meta entries and versions are errors (exit 3); unknown keys,
            type blocks and $ members are information (they are kept). A vault without settings is valid.
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable {
        struct Item: Encodable { var severity: String; var path: String; var message: String }
        var valid: Bool
        var issues: [Item]
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let issues = try vault.readSharedSettingsFile(allowNewerReader: true).map(SharedSettingsCatalog.issues(in:)) ?? []
        let valid = !issues.contains { $0.severity == .error }
        if output.json {
            try output.emitJSON(Out(valid: valid, issues: issues.map { .init(severity: $0.severity.rawValue, path: $0.path, message: $0.message) }))
        } else {
            for i in issues { print(i.description) }
            output.info(valid ? "settings valid" : "settings invalid")
        }
        if !valid { throw ExitCode(ExitStatus.unhealthy) }
    }
}

struct SettingsSchema: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Print the JSON Schema of the settings file (docs/settings.schema.json), from this version's registry."
    )

    func run() throws {
        FileHandle.standardOutput.write(try SharedSettingsSchema.json())
    }
}
