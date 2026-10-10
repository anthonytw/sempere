import Age
import Foundation

// Shared settings (format.md §13, docs/settings-sync.md): one file at the vault
// root, `settings.age`, whose plaintext is a VS Code-style settings.json: flat
// dotted keys, optional `[mac]` / `[ipad]` / `[iphone]` blocks, `$meta` with each
// key's last write, `$schemaVersion`. This file has the model, the merge,
// resolution and the vault's read and write; the registry of known settings is
// `SharedSettingsCatalog`, versions `SharedSettingsMigrations`, the per-device
// logic `SettingsSyncState`.

/// A kind of device whose settings can differ (format.md §13.2 type blocks).
public enum SettingsDeviceType: String, CaseIterable, Hashable, Sendable, Codable {
    case mac, ipad, iphone

    /// The block's member name: `[mac]`.
    public var blockName: String { "[\(rawValue)]" }
}

/// Why a settings file was not accepted (format.md §13, §9). Problems inside an
/// accepted file (an invalid value, a malformed `$meta` entry) are not errors:
/// they are reported as warnings and the rest of the file is used.
public enum SharedSettingsError: Error, Hashable, Sendable {
    /// The file (encrypted, or its JSON) is larger than the limits allow, or
    /// holds more keys or blocks than they allow.
    case tooLarge
    /// The plaintext is not a JSON object.
    case invalid(String)
    /// The file could not be decrypted with the identities held.
    case undecryptable(String)
    /// Framing (format.md §4) failed: bad magic, version, or a tag that
    /// verifies under neither the current nor (during a rewrap) the previous secret.
    case framing(BodyFramingError)
    /// A slot cannot be written: its `modified` would pass the largest time
    /// the format allows.
    case clockExhausted(String)
    /// The file's `$minReaderVersion` is later than this reader
    /// (`SharedSettingsMigrations.current`): it must not be read, applied or
    /// written (docs/settings-sync.md §6.2 rule 4).
    case needsNewerReader(minReaderVersion: Int)
}

/// Where a slot is: one key at the top level (`block == nil`) or inside a type
/// block (`block` is the type name inside the brackets, known or not).
public struct SettingSlotKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var block: String?
    public var key: String

    public init(_ key: String, block: String? = nil) { self.key = key; self.block = block }

    /// The slot of `key` in `type`'s block.
    public init(_ key: String, type: SettingsDeviceType) { self.init(key, block: type.rawValue) }

    public var description: String { block.map { "[\($0)] \(key)" } ?? key }

    public static func < (a: Self, b: Self) -> Bool { (a.block ?? "", a.key) < (b.block ?? "", b.key) }
}

/// When a slot was last written, and by which kind of device (`$meta`).
public struct SettingSlotMeta: Hashable, Sendable {
    /// Unix milliseconds, 0 ... `SharedSettings.maxModified`.
    public var modified: Int64
    /// `mac`, `ipad`, `iphone` (any lowercase name is kept); nil for the CLI.
    public var type: String?
    /// Members this version does not know, kept as read.
    public var extra: [String: JSONValue]

    public init(modified: Int64, type: String? = nil, extra: [String: JSONValue] = [:]) {
        self.modified = modified; self.type = type; self.extra = extra
    }

    var json: JSONValue {
        var o = extra
        o["modified"] = .number(Double(modified))
        if let type { o["type"] = .string(type) }
        return .object(o)
    }
}

/// One key's value (nil: reset to the default) and its `$meta` entry (nil:
/// written by hand, older than any write with one). Never both nil.
public struct SettingSlot: Hashable, Sendable {
    public var value: JSONValue?
    public var meta: SettingSlotMeta?

    public init(value: JSONValue?, meta: SettingSlotMeta?) { self.value = value; self.meta = meta }

    /// The merge order (format.md §13.3): `modified` (none lowest), the writer's
    /// type (none lowest), the canonical value (a reset lowest), then the whole
    /// slot. A total order: two different slots never tie.
    static func precedes(_ a: SettingSlot, _ b: SettingSlot) -> Bool {
        let am = a.meta?.modified ?? -1, bm = b.meta?.modified ?? -1
        if am != bm { return am < bm }
        let at = a.meta?.type ?? "", bt = b.meta?.type ?? ""
        if at != bt { return at < bt }
        let av = a.value.map { [1] + SharedSettings.canonical($0) } ?? [0]
        let bv = b.value.map { [1] + SharedSettings.canonical($0) } ?? [0]
        if av != bv { return av.lexicographicallyPrecedes(bv) }
        let ae = SharedSettings.canonical(a.meta?.json ?? .null), be = SharedSettings.canonical(b.meta?.json ?? .null)
        return ae.lexicographicallyPrecedes(be)
    }
}

/// The contents of `settings.age` (format.md §13).
public struct SharedSettings: Hashable, Sendable {
    /// The file at the vault root.
    public static let fileName = "settings.age"
    /// What the body tag has where a revision has its note id (format.md §13.1).
    public static let tagScope = "settings"
    /// Largest encrypted file read.
    public static let maxFileBytes = 1 << 20
    /// Largest decompressed JSON.
    public static let maxJSONBytes = 1 << 20
    /// Most slots (top level and blocks together) a file may hold.
    public static let maxSlots = 4096
    /// Most type blocks a file may hold.
    public static let maxBlocks = 32
    /// Largest `modified` (2^53 − 1, exact in every JSON reader).
    public static let maxModified: Int64 = (1 << 53) - 1

    /// `$schemaVersion` (format.md §13.4): of the file as read (after
    /// migrations, `SharedSettingsMigrations.current` unless it was newer).
    public var schemaVersion: Int
    /// `$minReaderVersion`: the oldest reader that may read and write the file.
    public var minReaderVersion: Int
    /// Every slot, top level and type blocks.
    public var slots: [SettingSlotKey: SettingSlot]
    /// Top-level members this version does not interpret (other `$…` members,
    /// a `[…]` member that is not an object), kept as read.
    public var extra: [String: JSONValue]

    public init(schemaVersion: Int = SharedSettingsMigrations.current,
                minReaderVersion: Int = SharedSettingsMigrations.minReaderVersion,
                slots: [SettingSlotKey: SettingSlot] = [:], extra: [String: JSONValue] = [:]) {
        self.schemaVersion = schemaVersion; self.minReaderVersion = minReaderVersion; self.slots = slots; self.extra = extra
    }

    /// Whether a reader of `version` may read and write this file (docs/settings-sync.md §6.2 rule 3).
    public func isReadable(byReader version: Int = SharedSettingsMigrations.current) -> Bool {
        minReaderVersion <= version
    }

    /// True when no slot is stored.
    public var isEmpty: Bool { slots.isEmpty }

    /// The value at `slot`, nil when absent or reset.
    public func value(_ slot: SettingSlotKey) -> JSONValue? { slots[slot]?.value }

    // MARK: Merge

    /// Per slot, the one later in the merge order; commutative, associative and
    /// idempotent (format.md §13.3). `$schemaVersion` is the larger; unknown
    /// top-level members are united, the greater canonical JSON winning on a
    /// clash (so the result does not depend on which copy merges which, and two
    /// devices holding different values converge instead of each writing its own back).
    public func merging(_ other: SharedSettings) -> SharedSettings {
        var out = self
        for (key, theirs) in other.slots {
            if let mine = out.slots[key], !SettingSlot.precedes(mine, theirs) { continue }
            out.slots[key] = theirs
        }
        out.schemaVersion = max(schemaVersion, other.schemaVersion)
        out.minReaderVersion = max(minReaderVersion, other.minReaderVersion)
        out.extra.merge(other.extra) { mine, theirs in
            Self.canonical(mine).lexicographicallyPrecedes(Self.canonical(theirs)) ? theirs : mine
        }
        return out
    }

    /// Writes `value` (nil: a reset) at `slot` as a device of `type` (nil: the
    /// CLI) at `now`: `modified = max(now, m + 1)`, `m` the `modified` held for
    /// the slot (format.md §13.3), so the write wins over what the writer saw
    /// whatever the clocks say.
    ///
    /// - Throws: `SharedSettingsError.clockExhausted` when `m` is already the largest time.
    public mutating func set(_ slot: SettingSlotKey, to value: JSONValue?, type: SettingsDeviceType?, now: Date) throws {
        var modified = Self.millis(now)
        if let held = slots[slot]?.meta?.modified {
            guard held < Self.maxModified else { throw SharedSettingsError.clockExhausted(slot.description) }
            modified = max(modified, held + 1)
        }
        slots[slot] = SettingSlot(value: value, meta: SettingSlotMeta(modified: modified, type: type?.rawValue))
    }

    /// `date` as Unix milliseconds within 0 ... `maxModified`.
    static func millis(_ date: Date) -> Int64 {
        let ms = date.timeIntervalSince1970 * 1000
        guard ms.isFinite, ms > 0 else { return 0 }
        return ms >= Double(maxModified) ? maxModified : Int64(ms)
    }

    // MARK: Resolution

    /// Where a device's value of a setting came from (format.md §13.2).
    public enum Source: String, Hashable, Sendable {
        case block, top, `default`
    }

    /// What a setting resolves to on a device of `type` (format.md §13.2, steps
    /// 2–4; the local override is the device's): its block's value, else the
    /// top level's, else the default. An invalid value is skipped and named in
    /// `warnings`.
    public struct Resolved: Hashable, Sendable {
        public var value: JSONValue
        public var source: Source
        public var warnings: [String] = []
    }

    ///
    /// A setting with legacy keys (docs/settings-sync.md §6.2 rule 2) resolves,
    /// at each level, from whichever of its key and its legacy keys was written
    /// last, a legacy value mapped to the current meaning.
    public func resolve(_ spec: SharedSettingSpec, for type: SettingsDeviceType?) -> Resolved {
        var warnings: [String] = []
        var levels: [(String?, Source)] = []
        if let type { levels.append((type.rawValue, .block)) }
        levels.append((nil, .top))
        for (block, source) in levels {
            // The latest written slot of the setting at this level decides it.
            guard let (slot, latest) = latestSlot(spec, block: block), let raw = latest.value else { continue }
            let mapped = slot.key == spec.name ? raw : spec.legacy.first { $0.name == slot.key }.flatMap { $0.fromLegacy(raw) }
            if let mapped, let ok = spec.validated(mapped) { return Resolved(value: ok, source: source, warnings: warnings) }
            warnings.append("\(slot): invalid value for \(spec.name) (\(spec.valuesDescription)); ignored")
        }
        return Resolved(value: spec.defaultValue, source: .default, warnings: warnings)
    }

    /// The slot of `spec` (its key or a legacy key) at `block` written last.
    func latestSlot(_ spec: SharedSettingSpec, block: String?) -> (SettingSlotKey, SettingSlot)? {
        var best: (SettingSlotKey, SettingSlot)?
        for name in [spec.name] + spec.legacy.map(\.name) {
            let key = SettingSlotKey(name, block: block)
            guard let slot = slots[key] else { continue }
            if let b = best, !SettingSlot.precedes(b.1, slot) { continue }
            best = (key, slot)
        }
        return best
    }

    /// True when the file has any slot of `spec` (its key or a legacy key) at `block`.
    public func hasSlot(_ spec: SharedSettingSpec, block: String?) -> Bool { latestSlot(spec, block: block) != nil }

    /// Writes `value` (nil: a reset) for `spec` at `block` (nil: the top level),
    /// and its legacy keys with the value mapped to their meaning (the dual-write
    /// window, docs/settings-sync.md §6.2 rule 2).
    public mutating func write(_ spec: SharedSettingSpec, _ value: JSONValue?, block: String?, type: SettingsDeviceType?,
                               now: Date) throws {
        try set(SettingSlotKey(spec.name, block: block), to: value, type: type, now: now)
        for legacy in spec.legacy {
            let old: JSONValue? = value.flatMap { legacy.toLegacy($0) }
            try set(SettingSlotKey(legacy.name, block: block), to: old, type: type, now: now)
        }
    }

    // MARK: Encoding

    /// Sorted-key compact JSON of `value`, the encoding the merge order compares.
    static func canonical(_ value: JSONValue) -> [UInt8] {
        // Values were decoded from JSON or built by this module: always encodable.
        Array((try? InkJSON.encoder().encode(value)) ?? Data())
    }

    /// The JSON object (format.md §13.2), with or without `$meta`.
    public func jsonObject(includingMeta: Bool = true) -> JSONValue {
        var top = extra
        top["$schemaVersion"] = .number(Double(schemaVersion))
        top["$minReaderVersion"] = .number(Double(minReaderVersion))
        var meta: [String: JSONValue] = [:]
        var blocks: [String: [String: JSONValue]] = [:]
        var blockMeta: [String: [String: JSONValue]] = [:]
        for (key, slot) in slots {
            if let block = key.block {
                let name = "[\(block)]"
                if let v = slot.value { blocks[name, default: [:]][key.key] = v }
                if let m = slot.meta { blockMeta[name, default: [:]][key.key] = m.json }
            } else {
                if let v = slot.value { top[key.key] = v }
                if let m = slot.meta { meta[key.key] = m.json }
            }
        }
        for (name, values) in blocks { top[name] = .object(values) }
        if includingMeta {
            for (name, metas) in blockMeta { meta[name] = .object(metas) }
            if !meta.isEmpty { top["$meta"] = .object(meta) }
        }
        return .object(top)
    }

    /// The file's JSON, keys sorted, indented for people (`sempere settings edit`).
    public func encoded(includingMeta: Bool = true) throws -> Data {
        let e = InkJSON.encoder()
        e.outputFormatting.insert(.prettyPrinted)
        return try e.encode(jsonObject(includingMeta: includingMeta))
    }

    /// A file read, and what in it was ignored.
    public struct Decoded: Hashable, Sendable {
        public var settings: SharedSettings
        /// Parts of the file that were ignored (a malformed `$meta` entry, a bad
        /// `$schemaVersion`), printable and short.
        public var warnings: [String]
    }

    /// Parses the file's JSON (format.md §13.2). Everything that can be used is
    /// used: a malformed `$meta` entry leaves its slot without one, a missing or
    /// bad `$schemaVersion` reads as 1; both are warnings. No migration runs.
    ///
    /// - Throws: `SharedSettingsError.tooLarge`, `.invalid` when the JSON is not
    ///   an object.
    public static func decode(_ json: Data) throws -> Decoded {
        guard json.count <= maxJSONBytes else { throw SharedSettingsError.tooLarge }
        let root: JSONValue
        do { root = try InkJSON.decoder().decode(JSONValue.self, from: json) } catch {
            throw SharedSettingsError.invalid("not JSON")
        }
        guard case .object(var top) = root else { throw SharedSettingsError.invalid("not a JSON object") }
        var warnings: [String] = []
        func version(_ name: String) -> Int {
            switch top.removeValue(forKey: name) {
            case .number(let n)? where n.rounded(.towardZero) == n && n >= 1 && n <= 1_000_000_000:
                return Int(n)
            case nil:
                warnings.append("no \(name); read as 1")
            case .some:
                warnings.append("\(name) is not a positive integer; read as 1")
            }
            return 1
        }
        let schemaVersion = version("$schemaVersion")
        let minReader = version("$minReaderVersion")
        let metaObject: [String: JSONValue]
        switch top.removeValue(forKey: "$meta") {
        case .object(let o)?: metaObject = o
        case nil: metaObject = [:]
        case .some: metaObject = [:]; warnings.append("$meta is not an object; ignored")
        }
        var slots: [SettingSlotKey: SettingSlot] = [:]
        var extra: [String: JSONValue] = [:]
        var blockCount = 0
        for (name, value) in top {
            if name.hasPrefix("$") { extra[name] = value; continue }
            if let block = blockName(name) {
                guard case .object(let values) = value else { extra[name] = value; continue }
                blockCount += 1
                guard blockCount <= maxBlocks else { throw SharedSettingsError.tooLarge }
                for (k, v) in values { slots[SettingSlotKey(k, block: block)] = SettingSlot(value: v, meta: nil) }
            } else {
                slots[SettingSlotKey(name)] = SettingSlot(value: value, meta: nil)
            }
            guard slots.count <= maxSlots else { throw SharedSettingsError.tooLarge }
        }
        func attach(_ slot: SettingSlotKey, _ m: JSONValue) {
            guard let meta = Self.meta(m) else {
                warnings.append("$meta entry for \(printable(slot.description)) is malformed; ignored")
                return
            }
            slots[slot, default: SettingSlot(value: nil, meta: nil)].meta = meta
        }
        for (name, m) in metaObject {
            if let block = blockName(name) {
                guard case .object(let entries) = m else {
                    warnings.append("$meta entry \(printable(name)) is not an object; ignored")
                    continue
                }
                for (k, em) in entries { attach(SettingSlotKey(k, block: block), em) }
            } else {
                attach(SettingSlotKey(name), m)
            }
            guard slots.count <= maxSlots else { throw SharedSettingsError.tooLarge }
        }
        return Decoded(settings: SharedSettings(schemaVersion: schemaVersion, minReaderVersion: minReader, slots: slots,
                                                extra: extra), warnings: warnings)
    }

    /// The type name of a block member `[name]`: lowercase letters and digits,
    /// starting with a letter, at most 16. Nil for any other member name.
    static func blockName(_ member: String) -> String? {
        guard member.hasPrefix("["), member.hasSuffix("]"), member.utf8.count >= 3 else { return nil }
        let inner = String(member.dropFirst().dropLast())
        let b = Array(inner.utf8)
        guard b.count <= 16, let first = b.first, (0x61...0x7a).contains(first),
              b.allSatisfy({ (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) }) else { return nil }
        return inner
    }

    private static func meta(_ value: JSONValue) -> SettingSlotMeta? {
        guard case .object(var o) = value,
              case .number(let m)? = o.removeValue(forKey: "modified"), m.rounded(.towardZero) == m, m >= 0,
              m <= Double(maxModified) else { return nil }
        var type: String?
        switch o.removeValue(forKey: "type") {
        case nil: break
        case .string(let t)? where blockName("[\(t)]") != nil: type = t
        case .some: return nil
        }
        return SettingSlotMeta(modified: Int64(m), type: type, extra: o)
    }

    /// `s` cut to 64 printable ASCII characters (others become `?`), for messages.
    public static func printable(_ s: String) -> String {
        String(s.unicodeScalars.prefix(64).map { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f ? Character($0) : "?" })
    }
}

extension SharedSettings: Codable {
    /// The file's JSON object, for keeping a copy outside the vault.
    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        self = try Self.decode(try InkJSON.encoder().encode(value)).settings
    }

    public func encode(to encoder: Encoder) throws {
        try jsonObject().encode(to: encoder)
    }
}

// MARK: - The vault's file

extension Vault {
    /// `settings.age` at the vault root (format.md §13).
    public var sharedSettingsURL: URL { url.appendingPathComponent(SharedSettings.fileName) }

    /// True when the vault holds a settings file.
    public var hasSharedSettings: Bool { FileIO.exists(sharedSettingsURL) }

    /// Reads `settings.age` and migrates it to this version's `$schemaVersion`
    /// (in memory only: format.md §13.4); nil when the vault has none.
    /// Warnings are dropped: `readSharedSettingsFile` has them.
    public func readSharedSettings() throws -> SharedSettings? {
        try readSharedSettingsFile().map { SharedSettingsMigrations.migrated($0.settings) }
    }

    /// Reads, decrypts and verifies `settings.age`, as written (no migration);
    /// nil when the vault has none.
    ///
    /// - Throws: `VaultError.legacyVault`, `.locked`, `.noIdentities`;
    ///   `SharedSettingsError` for a file that is too large, cannot be
    ///   decrypted, does not verify (format.md §4 tag, scope `settings`), or
    ///   is not a JSON object.
    ///
    /// - Parameter allowNewerReader: also return a file whose `$minReaderVersion`
    ///   is later than this reader (for `settings validate` only: such a file is
    ///   never applied or written).
    public func readSharedSettingsFile(allowNewerReader: Bool = false) throws -> SharedSettings.Decoded? {
        try requireMigrated()
        _ = try requireReadable()
        let file = sharedSettingsURL
        guard FileIO.exists(file) else { return nil }
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
           size > SharedSettings.maxFileBytes {
            throw SharedSettingsError.tooLarge
        }
        return try openSharedSettings(try FileIO.read(file, maxBytes: SharedSettings.maxFileBytes),
                                      allowNewerReader: allowNewerReader)
    }

    /// Decrypts, verifies and decodes the bytes of a `settings.age` (a copy from
    /// a sync server, say), as `readSharedSettingsFile` does the vault's own.
    public func openSharedSettings(_ data: Data, allowNewerReader: Bool = false) throws -> SharedSettings.Decoded {
        try requireMigrated()
        let secret = try requireReadable()
        guard data.count <= SharedSettings.maxFileBytes else { throw SharedSettingsError.tooLarge }
        let plain: Data
        do { plain = try AgeFile.decrypt(data, with: identities) } catch {
            throw SharedSettingsError.undecryptable(SharedSettings.printable("\(error)"))
        }
        let unframed: BodyFraming.Unframed
        do {
            unframed = try Self.unframeSettings(plain, secret: secret, previous: previousSecret)
        } catch let e as BodyFramingError {
            throw SharedSettingsError.framing(e)
        }
        let json: Data
        do { json = try Gzip.decompress(unframed.gzip, maxOutput: SharedSettings.maxJSONBytes) } catch {
            throw SharedSettingsError.invalid("gzip: \(SharedSettings.printable("\(error)"))")
        }
        let decoded = try SharedSettings.decode(json)
        guard allowNewerReader || decoded.settings.isReadable() else {
            throw SharedSettingsError.needsNewerReader(minReaderVersion: decoded.settings.minReaderVersion)
        }
        return decoded
    }

    /// True when `vault.json` on disk still lists this value's recipients and wraps the same
    /// secret; false after another device changed the keys while this one stayed open (its
    /// secret and recipients are then stale), or when the manifest cannot be read. A settings
    /// file that does not verify is replaced only when this holds: a stale device must not
    /// overwrite the current file with one encrypted to the old recipients (format.md §13.5).
    public func keysMatchManifestOnDisk() -> Bool {
        guard let data = try? FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes),
              let onDisk = try? Self.readManifest(data) else { return false }
        return onDisk.vaultSecret == manifest.vaultSecret && onDisk.recipients.map(\.key) == manifest.recipients.map(\.key)
    }

    /// Unframes under the current secret, or (a rewrap in progress) the previous one.
    static func unframeSettings(_ plain: Data, secret: VaultSecret, previous: VaultSecret?) throws -> BodyFraming.Unframed {
        do {
            return try BodyFraming.unframe(plain, noteId: SharedSettings.tagScope, filename: SharedSettings.fileName,
                                           secret: secret)
        } catch BodyFramingError.tagMismatch {
            guard let previous else { throw BodyFramingError.tagMismatch }
            return try BodyFraming.unframe(plain, noteId: SharedSettings.tagScope, filename: SharedSettings.fileName,
                                           secret: previous)
        }
    }

    /// Writes `settings` as `settings.age`, replacing the file atomically. A
    /// vault write: refused for legacy and read-only vaults and a tampered
    /// recipients list (`requireWritable`).
    public func writeSharedSettings(_ settings: SharedSettings) throws {
        try requireMigrated()
        try requireWritable()
        let secret = try requireSecret()
        let body = try BodyFraming.frame(json: try settings.encoded(), noteId: SharedSettings.tagScope,
                                         filename: SharedSettings.fileName, secret: secret)
        try FileIO.writeAtomically(try Self.encrypt(body, to: try ageRecipients()), to: sharedSettingsURL, replacing: true)
    }

    /// Reads the file, lets `change` edit it, merges in whatever the file holds
    /// just before writing (another process may have written meanwhile), and
    /// writes the result. Returns what was written.
    ///
    /// - Parameter replacingUnreadable: when the file exists but cannot be
    ///   read (it does not verify or decode), start from an empty set and
    ///   replace it; otherwise that error is thrown. A file that needs a
    ///   newer reader is never replaced (`needsNewerReader`).
    @discardableResult
    public func updateSharedSettings(replacingUnreadable: Bool = false,
                                     _ change: (inout SharedSettings) throws -> Void) throws -> SharedSettings {
        try requireWritable()
        var settings = try readSharedSettingsForUpdate(replacingUnreadable: replacingUnreadable) ?? SharedSettings()
        try change(&settings)
        if let latest = try readSharedSettingsForUpdate(replacingUnreadable: replacingUnreadable) {
            settings = settings.merging(latest)
        }
        try writeSharedSettings(settings)
        return settings
    }

    private func readSharedSettingsForUpdate(replacingUnreadable: Bool) throws -> SharedSettings? {
        do { return try readSharedSettings() } catch let e as SharedSettingsError {
            if case .needsNewerReader = e { throw e }   // never replaced (docs/settings-sync.md §6.2 rule 4)
            if replacingUnreadable { return nil }
            throw e
        }
    }

    /// Rewrites `settings.age` for the current recipients during a recipient
    /// change (format.md §3.3.1 step 3): re-encrypted, and re-tagged under the
    /// current secret after verifying under it or the previous one. A file that
    /// cannot be decrypted or verified is left as it is and listed in
    /// `settingsSkipped`; it does not keep the journal.
    func rewrapSharedSettings(recipients: [NativeRecipient], report: inout RewrapReport, stopAfter: Int?) throws {
        let file = sharedSettingsURL
        guard FileIO.exists(file), !FileIO.isDirectory(file) else { return }
        let name = SharedSettings.fileName
        let current = try requireSecret()
        guard let data = try? FileIO.read(file, maxBytes: SharedSettings.maxFileBytes),
              let stanzas = try? Self.stanzaCounts(data),
              let plain = try? AgeFile.decrypt(data, with: identities),
              let unframed = try? Self.unframeSettings(plain, secret: current, previous: previousSecret) else {
            report.settingsSkipped.append(name)
            return
        }
        let tagged = (try? BodyFraming.unframe(plain, noteId: SharedSettings.tagScope, filename: name, secret: current)) != nil
        if tagged, stanzas == Self.expectedStanzas(recipients) {
            report.alreadyCurrent.append(name)
            return
        }
        if let stopAfter, report.rewrapped.count >= stopAfter { throw VaultError.interrupted }
        let body = BodyFraming.retag(unframed, noteId: SharedSettings.tagScope, filename: name, secret: current)
        try FileIO.writeAtomically(try Self.encrypt(body, to: recipients), to: file, replacing: true)
        report.rewrapped.append(name)
    }
}
