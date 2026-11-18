import Foundation

// Custom saved tools (docs/design/1.3-custom-tools.md, issue #11): a preset is a shortcut to a
// `DrawingToolState` (ink, color, width, opacity), stored in the vault's shared settings one slot per
// preset (`palette.tool.<uuid>`) plus one order slot (`palette.toolOrder`). Pure and Linux-tested: the
// app's palette and `sempere tools` both go through it.

/// A saved tool: one palette entry.
public struct SavedTool: Hashable, Sendable {
    /// Most presets (live ones; an existing file with more shows the first `maxTools` by order).
    public static let maxTools = 64
    /// Longest name, in characters, after trimming.
    public static let maxNameLength = 40
    /// Largest encoded slot, in bytes.
    public static let maxSlotBytes = 4096
    /// The key family of a preset's slot: `palette.tool.<uuid>`.
    public static let keyPrefix = "palette.tool."
    /// The order slot.
    public static let orderKey = "palette.toolOrder"

    /// A lowercase UUID.
    public var id: String
    /// 1 ... 40 characters, trimmed, NFC.
    public var name: String
    public var ink: InkTool
    /// Opaque, as drawn on light paper.
    public var color: Color
    /// In PencilKit tool units, inside `DrawingToolState.widthRange(for: ink)`.
    public var width: Double
    /// 0.05 ... 1.
    public var opacity: Double
    /// Creation time, Unix milliseconds.
    public var at: Int64
    /// Members this version does not know, kept as read.
    public var extra: [String: JSONValue]

    public init(id: String = SavedTool.newID(), name: String, ink: InkTool, color: Color, width: Double,
                opacity: Double = 1, at: Int64, extra: [String: JSONValue] = [:]) {
        self.id = id; self.name = name; self.ink = ink; self.color = color; self.width = width
        self.opacity = opacity; self.at = at; self.extra = extra
    }

    /// A fresh id.
    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// The slot key of `id`.
    public static func key(for id: String) -> String { keyPrefix + id }

    /// The id in a slot key `palette.tool.<id>`, nil when `key` is not one (a lowercase 36-character UUID).
    public static func id(fromKey key: String) -> String? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let id = String(key.dropFirst(keyPrefix.count))
        return isValidID(id) ? id : nil
    }

    /// Whether `id` is a lowercase UUID.
    public static func isValidID(_ id: String) -> Bool {
        let b = Array(id.utf8)
        guard b.count == 36 else { return false }
        for (i, c) in b.enumerated() {
            if [8, 13, 18, 23].contains(i) { if c != UInt8(ascii: "-") { return false } } else if
                !((0x30...0x39).contains(c) || (0x61...0x66).contains(c)) { return false }
        }
        return true
    }

    /// `name` trimmed and in NFC, nil when it is empty, longer than `maxNameLength` or holds a control character.
    public static func cleanName(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !n.isEmpty, n.count <= maxNameLength,
              !n.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return n
    }

    /// `text` (`#RRGGBB`, any case) as an opaque color.
    public static func color(fromHex text: String) -> Color? {
        guard text.utf8.count == 7, text.hasPrefix("#"), let c = Color(hex: text) else { return nil }
        return Color(r: c.r, g: c.g, b: c.b)
    }

    /// `#RRGGBB`.
    public static func hex(_ color: Color) -> String { String(color.hex.prefix(7)) }

    /// What is wrong with the values, nil when none: the rules of design §3.1.
    public func problem() -> String? {
        if !Self.isValidID(id) { return "the id is not a lowercase UUID" }
        if Self.cleanName(name) != name { return "the name must be 1 to \(Self.maxNameLength) characters, trimmed, with no control characters" }
        if color.a != 255 { return "the color must be opaque (#RRGGBB)" }
        let range = DrawingToolState.widthRange(for: ink)
        if !(width.isFinite && range.contains(width)) {
            return "the width must be within \(Self.number(range.lowerBound)) to \(Self.number(range.upperBound)) for \(ink.rawValue)"
        }
        if !(opacity.isFinite && opacity >= 0.05 && opacity <= 1) { return "the opacity must be within 0.05 to 1" }
        if at < 0 || at > SharedSettings.maxModified { return "the creation time is out of range" }
        if let json = try? InkJSON.encoder().encode(jsonValue), json.count > Self.maxSlotBytes { return "the preset is too large" }
        return nil
    }

    /// A number as short text: `1.5`, `12`.
    public static func number(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    // MARK: JSON

    /// The slot's value (design §3.1).
    public var jsonValue: JSONValue {
        var o = extra
        o["name"] = .string(name)
        o["ink"] = .string(ink.rawValue)
        o["color"] = .string(Self.hex(color))
        o["width"] = .number(width)
        o["opacity"] = .number(opacity)
        o["at"] = .number(Double(at))
        return .object(o)
    }

    /// Why a slot's value is not a preset.
    public enum ParseFailure: Error, Hashable, Sendable {
        /// An ink this version does not know (a newer app's): the preset is hidden and kept.
        case unknownInk(String)
        /// Anything else: the preset is skipped with this reason.
        case invalid(String)
    }

    /// Reads the value of slot `id`. Never traps; an unknown ink is not read as the pen (format.md §5.6).
    public static func parse(id: String, _ value: JSONValue) -> Result<SavedTool, ParseFailure> {
        guard isValidID(id) else { return .failure(.invalid("the key is not palette.tool.<lowercase uuid>")) }
        guard case .object(var o) = value else { return .failure(.invalid("not an object")) }
        if let data = try? InkJSON.encoder().encode(value), data.count > maxSlotBytes { return .failure(.invalid("larger than \(maxSlotBytes) bytes")) }
        guard case .string(let rawName)? = o.removeValue(forKey: "name"), let name = cleanName(rawName), name == rawName else {
            return .failure(.invalid("name must be 1 to \(maxNameLength) characters, trimmed"))
        }
        guard case .string(let rawInk)? = o.removeValue(forKey: "ink") else { return .failure(.invalid("ink is missing")) }
        guard let ink = InkTool(rawValue: rawInk) else { return .failure(.unknownInk(SharedSettings.printable(rawInk))) }
        guard case .string(let hex)? = o.removeValue(forKey: "color"), let color = color(fromHex: hex) else {
            return .failure(.invalid("color must be #RRGGBB"))
        }
        let range = DrawingToolState.widthRange(for: ink)
        guard case .number(let width)? = o.removeValue(forKey: "width"), width.isFinite, range.contains(width) else {
            return .failure(.invalid("width must be within \(number(range.lowerBound)) to \(number(range.upperBound)) for \(rawInk)"))
        }
        guard case .number(let opacity)? = o.removeValue(forKey: "opacity"), opacity.isFinite, opacity >= 0.05, opacity <= 1 else {
            return .failure(.invalid("opacity must be within 0.05 to 1"))
        }
        guard case .number(let at)? = o.removeValue(forKey: "at"), at.rounded(.towardZero) == at, at >= 0,
              at <= Double(SharedSettings.maxModified) else {
            return .failure(.invalid("at must be an integer time in Unix milliseconds"))
        }
        return .success(SavedTool(id: id, name: name, ink: ink, color: color, width: width, opacity: opacity, at: Int64(at), extra: o))
    }

    /// `problem` of a slot's value for `validate`: nil when the preset is valid or hidden (an unknown ink).
    static func slotProblem(key: String, _ value: JSONValue) -> String? {
        guard let id = id(fromKey: key) else { return "the key must be palette.tool.<lowercase uuid>" }
        if case .failure(.invalid(let why)) = parse(id: id, value) { return why }
        return nil
    }

    /// Whether `value` is a valid order slot: at most `maxTools` UUID strings.
    static func orderProblem(_ value: JSONValue) -> String? {
        guard case .array(let a) = value else { return "must be an array of preset ids" }
        guard a.count <= maxTools else { return "at most \(maxTools) ids" }
        for v in a {
            guard case .string(let s) = v, isValidID(s) else { return "every entry must be a lowercase uuid string" }
        }
        return nil
    }
}

/// Why a saved-tool change was refused (`sempere tools`, the app's editor).
public enum SavedToolError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalid(String)
    case tooMany
    case notFound(String)
    /// An id prefix or a name that several presets share (their ids).
    case ambiguous(String, [String])
    case badPosition(String)

    public var description: String {
        switch self {
        case .invalid(let why): return "invalid saved tool: \(why)"
        case .tooMany: return "at most \(SavedTool.maxTools) saved tools"
        case .notFound(let ref): return "no saved tool '\(SharedSettings.printable(ref))' (an id, an id prefix or an exact name)"
        case .ambiguous(let ref, let ids):
            return "'\(SharedSettings.printable(ref))' matches several saved tools; use an id: \(ids.joined(separator: ", "))"
        case .badPosition(let why): return why
        }
    }
}

/// The saved tools of a settings file or of a device's local list, in the user's order.
public struct SavedToolList: Hashable, Sendable {
    /// Shown, in order (at most `SavedTool.maxTools`).
    public private(set) var tools: [SavedTool]
    /// Slots that are not valid presets (key and reason), skipped.
    public private(set) var warnings: [String]
    /// Live presets that are not shown: an unknown ink, or beyond the 64th.
    public private(set) var hiddenCount: Int
    /// Live slots altogether (shown, hidden or beyond the cap).
    public private(set) var liveCount: Int

    public init(tools: [SavedTool] = []) {
        self.tools = Array(tools.prefix(SavedTool.maxTools)); warnings = []; hiddenCount = 0; liveCount = self.tools.count
    }

    /// The presets of `settings`' top level, ordered by `palette.toolOrder`: listed ids first (a missing or
    /// repeated one skipped), then the rest by `at`, then id. Slots inside type blocks are not read (design §3.2).
    public init(settings: SharedSettings) {
        var all: [String: SavedTool] = [:]
        var warnings: [String] = []
        var live = 0, hidden = 0
        for (slot, entry) in settings.slots where slot.block == nil && slot.key.hasPrefix(SavedTool.keyPrefix) {
            guard let value = entry.value else { continue }
            live += 1
            guard let id = SavedTool.id(fromKey: slot.key) else {
                warnings.append("\(SharedSettings.printable(slot.key)): not palette.tool.<lowercase uuid>; skipped")
                hidden += 1
                continue
            }
            switch SavedTool.parse(id: id, value) {
            case .success(let t): all[id] = t
            case .failure(.unknownInk): hidden += 1
            case .failure(.invalid(let why)):
                warnings.append("\(SharedSettings.printable(slot.key)): \(why); skipped")
                hidden += 1
            }
        }
        var order: [String] = []
        if case .array(let a)? = settings.value(SettingSlotKey(SavedTool.orderKey)) {
            for case .string(let s) in a.prefix(4096) where all[s] != nil && !order.contains(s) { order.append(s) }
        }
        let listed = Set(order)
        let rest = all.values.filter { !listed.contains($0.id) }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        let ordered = order.compactMap { all[$0] } + rest
        hidden += max(0, ordered.count - SavedTool.maxTools)
        self.tools = Array(ordered.prefix(SavedTool.maxTools))
        self.warnings = warnings.sorted()
        self.hiddenCount = hidden
        self.liveCount = live
    }

    public var isEmpty: Bool { tools.isEmpty }

    /// The shown preset with `id`.
    public func tool(id: String) -> SavedTool? { tools.first { $0.id == id } }

    /// The preset `ref` names: an id, an id prefix (at least 4 characters) or an exact name.
    public func resolve(_ ref: String) throws -> SavedTool {
        let r = ref.trimmingCharacters(in: .whitespaces)
        if let t = tool(id: r.lowercased()) { return t }
        if r.count >= 4 {
            let byPrefix = tools.filter { $0.id.hasPrefix(r.lowercased()) }
            if byPrefix.count == 1 { return byPrefix[0] }
            if byPrefix.count > 1 { throw SavedToolError.ambiguous(ref, byPrefix.map(\.id)) }
        }
        let byName = tools.filter { $0.name == r || $0.name == r.precomposedStringWithCanonicalMapping }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw SavedToolError.ambiguous(ref, byName.map(\.id)) }
        throw SavedToolError.notFound(ref)
    }

    // MARK: Writing to a settings file

    /// Adds `tool` as a new slot.
    public static func add(_ tool: SavedTool, to settings: inout SharedSettings, type: SettingsDeviceType? = nil,
                           now: Date = Date()) throws {
        if let p = tool.problem() { throw SavedToolError.invalid(p) }
        guard SavedToolList(settings: settings).liveCount < SavedTool.maxTools else { throw SavedToolError.tooMany }
        try settings.set(SettingSlotKey(SavedTool.key(for: tool.id)), to: tool.jsonValue, type: type, now: now)
    }

    /// Rewrites `tool`'s own slot (the later write wins for that preset only).
    public static func update(_ tool: SavedTool, in settings: inout SharedSettings, type: SettingsDeviceType? = nil,
                              now: Date = Date()) throws {
        if let p = tool.problem() { throw SavedToolError.invalid(p) }
        try settings.set(SettingSlotKey(SavedTool.key(for: tool.id)), to: tool.jsonValue, type: type, now: now)
    }

    /// Deletes a preset: a reset of its slot, so a device that still holds it does not bring it back.
    public static func remove(id: String, from settings: inout SharedSettings, type: SettingsDeviceType? = nil,
                              now: Date = Date()) throws {
        try settings.set(SettingSlotKey(SavedTool.key(for: id)), to: nil, type: type, now: now)
    }

    /// Writes `ids` (the shown presets, in order) as `palette.toolOrder`.
    public static func writeOrder(_ ids: [String], to settings: inout SharedSettings, type: SettingsDeviceType? = nil,
                                  now: Date = Date()) throws {
        try settings.set(SettingSlotKey(SavedTool.orderKey), to: .array(ids.prefix(SavedTool.maxTools).map { .string($0) }),
                         type: type, now: now)
    }

    /// Where a move puts a preset.
    public enum Destination: Hashable, Sendable {
        /// A 1-based position.
        case position(Int)
        case before(String)
        case after(String)
    }

    /// The order after moving `id` to `destination` (ids of the shown presets).
    public func order(moving id: String, to destination: Destination) throws -> [String] {
        var ids = tools.map(\.id)
        guard let from = ids.firstIndex(of: id) else { throw SavedToolError.notFound(id) }
        ids.remove(at: from)
        let at: Int
        switch destination {
        case .position(let n):
            guard n >= 1, n <= tools.count else { throw SavedToolError.badPosition("position must be 1 to \(tools.count)") }
            at = n - 1
        case .before(let other), .after(let other):
            guard other != id else { throw SavedToolError.badPosition("a saved tool cannot move relative to itself") }
            guard let i = ids.firstIndex(of: other) else { throw SavedToolError.notFound(other) }
            if case .before = destination { at = i } else { at = i + 1 }
        }
        ids.insert(id, at: at)
        return ids
    }

    /// Moves `id` in `settings`.
    public static func move(id: String, to destination: Destination, in settings: inout SharedSettings,
                            type: SettingsDeviceType? = nil, now: Date = Date()) throws {
        try writeOrder(SavedToolList(settings: settings).order(moving: id, to: destination), to: &settings, type: type, now: now)
    }

    /// Writes this list into `settings` as new slots and an order slot: seeds a vault that has none from a device's
    /// local list (design §3.3).
    public func seed(into settings: inout SharedSettings, type: SettingsDeviceType? = nil, now: Date = Date()) throws {
        for t in tools { try Self.add(t, to: &settings, type: type, now: now) }
        try Self.writeOrder(tools.map(\.id), to: &settings, type: type, now: now)
    }

    /// True when `settings` has any preset slot, live or reset, at the top level (turning sync on then follows §4.2).
    public static func hasSlots(in settings: SharedSettings) -> Bool {
        settings.slots.keys.contains { $0.block == nil && ($0.key.hasPrefix(SavedTool.keyPrefix) || $0.key == SavedTool.orderKey) }
    }

    // MARK: The device's local list (`Sempere.savedTools`)

    /// The list as JSON for `UserDefaults`: an array of the slot values, each with its id, in order.
    public func encoded() -> Data {
        let items: [JSONValue] = tools.map { t in
            guard case .object(var o) = t.jsonValue else { return t.jsonValue }
            o["id"] = .string(t.id)
            return .object(o)
        }
        return (try? InkJSON.encoder().encode(JSONValue.array(items))) ?? Data("[]".utf8)
    }

    /// The list stored by `encoded`; whatever is not a valid preset is skipped, a damaged value is an empty list.
    public init(decoding data: Data?) {
        var out: [SavedTool] = []
        if let data, data.count <= 1 << 20,
           case .array(let items)? = try? InkJSON.decoder().decode(JSONValue.self, from: data) {
            var seen = Set<String>()
            for case .object(var o) in items.prefix(4 * SavedTool.maxTools) {
                guard case .string(let id)? = o.removeValue(forKey: "id"), !seen.contains(id),
                      case .success(let t) = SavedTool.parse(id: id, .object(o)) else { continue }
                seen.insert(id)
                out.append(t)
            }
        }
        self.init(tools: out)
    }

    // MARK: Local edits (the device's list)

    /// Adds `tool` to a local list.
    public mutating func add(_ tool: SavedTool) throws {
        if let p = tool.problem() { throw SavedToolError.invalid(p) }
        guard tools.count < SavedTool.maxTools else { throw SavedToolError.tooMany }
        tools.append(tool); liveCount = tools.count
    }

    /// Replaces the preset with the same id in a local list.
    public mutating func update(_ tool: SavedTool) throws {
        if let p = tool.problem() { throw SavedToolError.invalid(p) }
        guard let i = tools.firstIndex(where: { $0.id == tool.id }) else { throw SavedToolError.notFound(tool.id) }
        tools[i] = tool
    }

    /// Removes a preset from a local list.
    public mutating func remove(id: String) {
        tools.removeAll { $0.id == id }; liveCount = tools.count
    }

    /// Moves a preset in a local list.
    public mutating func move(id: String, to destination: Destination) throws {
        let ids = try order(moving: id, to: destination)
        let byID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        tools = ids.compactMap { byID[$0] }
    }
}

// MARK: - The palette

extension DrawingToolState {
    /// Makes `saved` the current tool: its ink is selected and that ink's color, width and opacity become the
    /// preset's. A preset is a shortcut to a state, never a second kind of tool (design D2).
    public mutating func apply(_ saved: SavedTool) {
        select(DrawingTool(ink: saved.ink))
        setColor(saved.color, for: saved.ink)
        setWidth(saved.width, for: saved.ink)
        setOpacity(saved.opacity, for: saved.ink)
    }

    /// Whether the current tool is `saved`'s ink with exactly its color, and its width and opacity within a
    /// small tolerance: adjusting the width afterward deselects the preset, there is no hidden preset mode.
    public func isActive(_ saved: SavedTool) -> Bool {
        guard tool.ink == saved.ink, let s = currentInk else { return false }
        return s.color == saved.color && abs(s.width - saved.width) < 0.005 && abs(s.opacity - saved.opacity) < 0.005
    }

    /// A new preset from the current tool and its settings; nil for the eraser and the lasso, or a name that is
    /// not 1 to 40 characters.
    public func saving(name: String, id: String = SavedTool.newID(), now: Date = Date()) -> SavedTool? {
        guard let ink = tool.ink, let s = currentInk, let clean = SavedTool.cleanName(name) else { return nil }
        let t = SavedTool(id: id, name: clean, ink: ink, color: Color(r: s.color.r, g: s.color.g, b: s.color.b),
                          width: s.width, opacity: s.opacity, at: SharedSettings.millis(now))
        return t.problem() == nil ? t : nil
    }
}

// MARK: - Export and import (`sempere-tools/1`)

/// The file `sempere tools export` writes and `import` reads: `{ "format": "sempere-tools/1", "tools": [...] }`,
/// presets without ids.
public enum SavedToolFile {
    public static let format = "sempere-tools/1"
    /// Largest file read.
    public static let maxBytes = 1 << 20

    /// The file's JSON for `list`: sorted keys, indented, a final newline.
    public static func encode(_ list: SavedToolList) throws -> Data {
        let tools: [JSONValue] = list.tools.map { t in
            .object(["name": .string(t.name), "ink": .string(t.ink.rawValue), "color": .string(SavedTool.hex(t.color)),
                     "width": .number(t.width), "opacity": .number(t.opacity)])
        }
        let e = InkJSON.encoder()
        e.outputFormatting.insert(.prettyPrinted)
        return try e.encode(JSONValue.object(["format": .string(format), "tools": .array(tools)])) + Data("\n".utf8)
    }

    /// What an import read: presets with fresh ids (in file order) and a line for each entry skipped.
    public struct Parsed: Hashable, Sendable {
        public var tools: [SavedTool]
        public var skipped: [String]
    }

    /// Parses a file. Entries that are not valid presets are skipped and reported; at most `maxTools` entries are read.
    ///
    /// - Throws: `SavedToolError.invalid` when the data is not a `sempere-tools/1` file.
    public static func parse(_ data: Data, now: Date = Date()) throws -> Parsed {
        guard data.count <= maxBytes else { throw SavedToolError.invalid("the file is larger than \(maxBytes) bytes") }
        guard case .object(let top)? = try? InkJSON.decoder().decode(JSONValue.self, from: data),
              case .string(let f)? = top["format"], f == format, case .array(let entries)? = top["tools"] else {
            throw SavedToolError.invalid("not a \(format) file")
        }
        var tools: [SavedTool] = [], skipped: [String] = []
        let stamp = SharedSettings.millis(now)
        for (i, entry) in entries.enumerated() {
            guard i < SavedTool.maxTools else { skipped.append("entries beyond the \(SavedTool.maxTools)th skipped"); break }
            guard case .object(var o) = entry else { skipped.append("entry \(i + 1): not an object"); continue }
            o["at"] = .number(Double(stamp + Int64(i)))
            switch SavedTool.parse(id: SavedTool.newID(), .object(o)) {
            case .success(let t): tools.append(t)
            case .failure(.unknownInk(let ink)): skipped.append("entry \(i + 1): unknown ink '\(ink)'")
            case .failure(.invalid(let why)): skipped.append("entry \(i + 1): \(why)")
            }
        }
        return Parsed(tools: tools, skipped: skipped)
    }
}
