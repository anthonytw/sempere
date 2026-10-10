import Foundation

/// A setting this version knows (docs/settings-sync.md §5): its name, scope,
/// the values it accepts and its default. The app maps each to its stored
/// value; the CLI validates `settings set` with it.
public struct SharedSettingSpec: Sendable {
    /// What values a setting takes.
    public enum Kind: Hashable, Sendable {
        /// `true` or `false`.
        case bool
        /// One of these strings.
        case choice([String])
        /// One of these integers.
        case integer([Int])
        /// A custom title pattern (`DefaultTitle.check`, non-blank).
        case titlePattern
        /// A notebook path (`NotebookPath.canonical`; stored canonical).
        case notebook
        /// A paper object (format.md §5.4.2; stored validated).
        case paper
        /// A locale identifier, or `null` for "the device's".
        case localeOrNull
    }

    /// The key: `newNote.titleFormat`.
    public let name: String
    /// The device types that use it; nil: every device (docs/settings-sync.md §5).
    public let types: [SettingsDeviceType]?
    public let kind: Kind
    /// The value a device uses when nothing is set (and after a reset).
    public let defaultValue: JSONValue
    /// One line for `settings list` and the schema (English).
    public let summary: String
    /// Older keys of the same setting still written beside it (the dual-write
    /// window, docs/settings-sync.md §6.2 rule 2). None in version 1.
    public let legacy: [LegacyKey]

    /// An older key of a setting and how its values map to and from the current key's.
    public struct LegacyKey: Sendable {
        public var name: String
        /// The current value as the old key holds it (nil: the old key cannot say it; written as a reset).
        public var toLegacy: @Sendable (JSONValue) -> JSONValue?
        /// The old key's value in the current meaning (nil: unusable).
        public var fromLegacy: @Sendable (JSONValue) -> JSONValue?

        public init(_ name: String, toLegacy: @escaping @Sendable (JSONValue) -> JSONValue? = { $0 },
                    fromLegacy: @escaping @Sendable (JSONValue) -> JSONValue? = { $0 }) {
            self.name = name; self.toLegacy = toLegacy; self.fromLegacy = fromLegacy
        }
    }

    public init(_ name: String, types: [SettingsDeviceType]? = nil, _ kind: Kind, default defaultValue: JSONValue,
                _ summary: String, legacy: [LegacyKey] = []) {
        self.name = name; self.types = types; self.kind = kind; self.defaultValue = defaultValue; self.summary = summary
        self.legacy = legacy
    }

    /// Whether a device of `type` uses it.
    public func isUsed(by type: SettingsDeviceType) -> Bool { types?.contains(type) ?? true }

    /// `value` in its stored form when the setting accepts it, nil otherwise.
    public func validated(_ value: JSONValue) -> JSONValue? {
        switch kind {
        case .bool:
            if case .bool = value { return value }
        case .choice(let names):
            if case .string(let s) = value, names.contains(s) { return value }
        case .integer(let values):
            if case .number(let d) = value, d.rounded(.towardZero) == d, abs(d) < 1e15, values.contains(Int(d)) {
                return .number(d)
            }
        case .titlePattern:
            if case .string(let s) = value, s.count <= DefaultTitle.maxFormatLength,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               DefaultTitle.check(s, locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC") ?? .current) == nil {
                return value
            }
        case .notebook:
            // The capture bound, so a capture from this default is never cut.
            if case .string(let s) = value, s.unicodeScalars.count <= CaptureAdoption.maxNameScalars,
               s.count <= CaptureAdoption.maxNameLength, let c = NotebookPath.canonical(s) {
                return .string(c)
            }
        case .paper:
            if case .object = value, let paper = try? value.decode(Paper.self),
               let v = try? JSONValue(encoding: paper.validated()) {
                return v
            }
        case .localeOrNull:
            if value == .null { return value }
            if case .string(let s) = value, (1...35).contains(s.utf8.count),
               let first = s.utf8.first, (0x41...0x5a).contains(first) || (0x61...0x7a).contains(first),
               s.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0)
                   || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }) {
                return value
            }
        }
        return nil
    }

    /// Parses a command-line value: `true`/`false`/`on`/`off`/`yes`/`no` for
    /// switches, a number, a name, JSON for the paper, `null` or `device` for
    /// the device's locale. Nil when the text is not a value of the setting.
    public func parse(_ text: String) -> JSONValue? {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .bool:
            switch t.lowercased() {
            case "true", "on", "yes", "1": return .bool(true)
            case "false", "off", "no", "0": return .bool(false)
            default: return nil
            }
        case .integer:
            return Int(t).flatMap { validated(.number(Double($0))) }
        case .choice, .titlePattern, .notebook:
            return validated(.string(kind == .titlePattern ? text : t))
        case .paper:
            guard let data = t.data(using: .utf8),
                  let v = try? InkJSON.decoder().decode(JSONValue.self, from: data) else {
                return PaperKind(rawValue: t) == nil ? nil : validated(.object(["kind": .string(t)]))
            }
            return validated(v)
        case .localeOrNull:
            return ["null", "device", "none"].contains(t.lowercased()) ? .null : validated(.string(t))
        }
    }

    /// The values it accepts, for help and errors.
    public var valuesDescription: String {
        switch kind {
        case .bool: return "true or false"
        case .choice(let names): return names.joined(separator: ", ")
        case .integer(let values): return values.map(String.init).joined(separator: ", ")
        case .titlePattern: return "a title pattern (as notes new --title-format)"
        case .notebook: return "a notebook path"
        case .paper: return "a paper kind (ruled, grid, …) or a paper JSON object (format.md §5.4.2)"
        case .localeOrNull: return "a locale identifier (es_ES), or null for the device's"
        }
    }
}

/// Every setting this version syncs (docs/settings-sync.md §5): the registry
/// the JSON Schema (`SharedSettingsSchema`) is generated from.
public enum SharedSettingsCatalog {
    private static let touch: [SettingsDeviceType] = [.ipad, .iphone]

    /// The settings, in the order of docs/settings-sync.md §5.
    public static let specs: [SharedSettingSpec] = [
        .init("handwriting.recognize", .bool, default: .bool(true), "Recognize handwriting on the device"),
        .init("newNote.titleFormat", .choice(["dateAndTime", "dateOnly", "isoDateTime", "weekday", "custom", "blank"]),
              default: .string("dateAndTime"), "Title of a new note left untitled"),
        .init("newNote.titlePattern", .titlePattern, default: .string("yyyy-MM-dd HH:mm"),
              "Custom title pattern (newNote.titleFormat custom)"),
        .init("editor.defaultPaper", .paper, default: (try? JSONValue(encoding: Paper.ruled)) ?? .object(["kind": .string("ruled")]),
              "Paper of new notes"),
        .init("editor.defaultLayout", .choice(["letter", "a4", "pagelessLetter", "pagelessA4"]), default: .string("letter"),
              "Page layout of new notes"),
        .init("editor.compactPalette", .bool, default: .bool(false), "Compact tool palette"),
        .init("eraser.mode", .choice(["object", "pixel"]), default: .string("object"), "Eraser mode"),
        .init("eraser.objectRadius", .integer([4, 8, 16, 32]), default: .number(8), "Object eraser size, points"),
        .init("recording.codec", .choice(["aac", "he-aac", "alac"]), default: .string("aac"), "Recording format"),
        .init("recording.bitRate", .integer([24_000, 32_000, 48_000, 64_000, 96_000, 128_000]), default: .number(64_000),
              "Recording quality, bits per second"),
        .init("recording.sampleRate", .integer([16_000, 22_050, 32_000, 44_100, 48_000]), default: .number(48_000),
              "Recording sample rate, Hz"),
        .init("recording.channels", .integer([1, 2]), default: .number(1), "Recording channels"),
        .init("transcription.enabled", .bool, default: .bool(false), "Transcribe recordings on the device"),
        .init("transcription.language", .localeOrNull, default: .null, "Transcription language (null: the device's)"),
        .init("math.recognize", .bool, default: .bool(false), "Convert handwriting to math"),
        .init("photos.removeMetadata", .bool, default: .bool(true), "Remove location and camera data from photos"),
        .init("history.thinAfterDays", .integer([7, 14, 30, 90, 365, 0]), default: .number(30),
              "Thin autosaves older than this many days (0: never)"),
        .init("search.transcripts", .bool, default: .bool(false), "Search recording transcripts"),
        .init("rewrap.onAdd", .choice(["header", "reencrypt"]), default: .string("header"),
              "Rewrap attachments when adding a device"),
        .init("rewrap.onRemove", .choice(["header", "reencrypt"]), default: .string("reencrypt"),
              "Rewrap attachments when removing a device or upgrading keys"),
        .init("backup.reminderDays", .integer([0, 1, 3, 7, 14, 30]), default: .number(0),
              "Backup reminder after this many days (0: off)"),
        .init("editor.keepScreenOn", types: touch, .bool, default: .bool(false), "Keep the screen on while a note is open"),
        .init("mouse.smoothing", types: [.mac], .choice(["off", "light", "strong"]), default: .string("light"),
              "Smooth mouse and trackpad strokes"),
        .init("quickCapture.notebook", types: touch, .notebook, default: .string("Inbox"), "Notebook of quick voice notes"),
        .init("quickCapture.transcribe", types: touch, .bool, default: .bool(true), "Transcribe quick voice notes"),
        .init("appearance.icon", types: touch, .choice(["keyholeNib", "cemeteryDoor", "shadowS", "inkWind"]),
              default: .string("keyholeNib"), "Home-screen icon"),
    ]

    /// The setting `name`; nil for a key this version does not know.
    public static func spec(named name: String) -> SharedSettingSpec? { specs.first { $0.name == name } }

    /// Every key this version reads: the settings' keys and their legacy keys.
    public static var allKeyNames: Set<String> { Set(specs.flatMap { [$0.name] + $0.legacy.map(\.name) }) }

    /// The settings a device of `type` uses.
    public static func specs(for type: SettingsDeviceType) -> [SharedSettingSpec] { specs.filter { $0.isUsed(by: type) } }

    /// A problem `validate` found (docs/settings-sync.md §6).
    public struct Issue: Hashable, Sendable, CustomStringConvertible {
        public enum Severity: String, Hashable, Sendable { case error, info }
        public var severity: Severity
        /// The slot (`[mac] eraser.mode`), or a member name.
        public var path: String
        public var message: String
        public var description: String { "\(severity.rawValue): \(path): \(message)" }
    }

    /// Checks `decoded` against the registry (the schema's rules): invalid values
    /// of known keys and decoding warnings are errors; unknown keys, blocks and
    /// `$` members, and a newer `$schemaVersion`, are information.
    public static func issues(in decoded: SharedSettings.Decoded) -> [Issue] {
        var out = decoded.warnings.map { Issue(severity: .error, path: "file", message: $0) }
        let s = decoded.settings
        if !s.isReadable() {
            out.append(Issue(severity: .error, path: "$minReaderVersion",
                             message: "\(s.minReaderVersion) is newer than this reader (\(SharedSettingsMigrations.current)): update Sempere"))
        }
        if s.schemaVersion > SharedSettingsMigrations.current {
            out.append(Issue(severity: .info, path: "$schemaVersion",
                             message: "\(s.schemaVersion) is newer than \(SharedSettingsMigrations.current): keys this version does not know are kept"))
        }
        for key in s.slots.keys.sorted() {
            if let block = key.block, SettingsDeviceType(rawValue: block) == nil {
                out.append(Issue(severity: .info, path: key.description, message: "unknown type block [\(block)]; kept"))
                continue
            }
            guard let spec = spec(named: key.key) else {
                if !allKeyNames.contains(key.key) {
                    out.append(Issue(severity: .info, path: key.description, message: "unknown key; kept"))
                }
                continue
            }
            if let v = s.slots[key]?.value, spec.validated(v) == nil {
                out.append(Issue(severity: .error, path: key.description,
                                 message: "invalid value; expected \(spec.valuesDescription) (devices use the next level or the default)"))
            }
        }
        for name in s.extra.keys.sorted() {
            out.append(Issue(severity: name.hasPrefix("$") ? .info : .error, path: SharedSettings.printable(name),
                             message: name.hasPrefix("$") ? "unknown member; kept" : "a type block must be an object; kept as it is"))
        }
        return out
    }
}

/// The JSON Schema of the settings file (docs/settings.schema.json), generated
/// from `SharedSettingsCatalog`: a test checks the committed copy, and
/// `sempere settings schema` prints it.
public enum SharedSettingsSchema {
    /// The schema as a JSON value.
    public static var value: JSONValue {
        var keys: [String: JSONValue] = [:]
        for spec in SharedSettingsCatalog.specs { keys[spec.name] = property(spec) }
        let settings: JSONValue = .object(["type": .string("object"), "properties": .object(keys)])
        let meta: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("modified")]),
            "properties": .object([
                "modified": .object(["type": .string("integer"), "minimum": .number(0),
                                     "maximum": .number(Double(SharedSettings.maxModified)),
                                     "description": .string("Unix milliseconds of the last write")]),
                "type": .object(["type": .string("string"), "pattern": .string("^[a-z][a-z0-9]{0,15}$"),
                                 "description": .string("the kind of device that wrote it; absent for the CLI")]),
            ]),
        ])
        var props: [String: JSONValue] = [
            "$schemaVersion": .object(["type": .string("integer"), "minimum": .number(1),
                                       "description": .string("version of the keys' names and meanings; \(SharedSettingsMigrations.current) for this one")]),
            "$minReaderVersion": .object(["type": .string("integer"), "minimum": .number(1),
                                          "description": .string("the oldest reader that may read and write the file; \(SharedSettingsMigrations.minReaderVersion) for this one")]),
            "$meta": .object([
                "type": .string("object"),
                "description": .string("per key (and per key of each type block, under the block's name): its last write"),
                "patternProperties": .object([blockPattern: .object(["type": .string("object"),
                                                                     "additionalProperties": .object(["$ref": .string("#/$defs/meta")])])]),
                "additionalProperties": .object(["$ref": .string("#/$defs/meta")]),
            ]),
        ]
        for t in SettingsDeviceType.allCases {
            props[t.blockName] = .object(["$ref": .string("#/$defs/settings"),
                                          "description": .string("values for \(t.rawValue) devices only; they win over the top level there")])
        }
        return .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "$id": .string("https://github.com/anthonytw/sempere/blob/main/docs/settings.schema.json"),
            "title": .string("Sempere shared settings"),
            "description": .string("The plaintext of a vault's settings.age (format.md §13). Generated from SharedSettingsCatalog; do not edit by hand."),
            "type": .string("object"),
            "required": .array([.string("$schemaVersion"), .string("$minReaderVersion")]),
            "allOf": .array([.object(["$ref": .string("#/$defs/settings")])]),
            "properties": .object(props),
            "patternProperties": .object([blockPattern: .object(["type": .string("object")])]),
            "$defs": .object(["settings": settings, "meta": meta]),
        ])
    }

    static let blockPattern = "^\\[[a-z][a-z0-9]{0,15}\\]$"

    /// The schema file's bytes: sorted keys, indented, a final newline.
    public static func json() throws -> Data {
        let e = InkJSON.encoder()
        e.outputFormatting.insert(.prettyPrinted)
        return try e.encode(value) + Data("\n".utf8)
    }

    static func property(_ spec: SharedSettingSpec) -> JSONValue {
        var o: [String: JSONValue]
        switch spec.kind {
        case .bool: o = ["type": .string("boolean")]
        case .choice(let names): o = ["enum": .array(names.map { .string($0) })]
        case .integer(let values): o = ["enum": .array(values.map { .number(Double($0)) })]
        case .titlePattern: o = ["type": .string("string"), "minLength": .number(1), "maxLength": .number(Double(DefaultTitle.maxFormatLength))]
        case .notebook: o = ["type": .string("string"), "minLength": .number(1), "maxLength": .number(Double(CaptureAdoption.maxNameLength))]
        case .paper:
            o = ["type": .string("object"), "required": .array([.string("kind")]),
                 "properties": .object(["kind": .object(["type": .string("string")])])]
        case .localeOrNull:
            o = ["oneOf": .array([.object(["type": .string("null")]),
                                  .object(["type": .string("string"), "pattern": .string("^[A-Za-z][A-Za-z0-9_-]{0,34}$")])])]
        }
        let used = spec.types.map { " Used by: \($0.map(\.rawValue).joined(separator: ", "))." } ?? ""
        o["description"] = .string(spec.summary + "." + used)
        o["default"] = spec.defaultValue
        return .object(o)
    }
}
