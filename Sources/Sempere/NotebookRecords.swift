import Age
import Foundation

/// One notebook record (format.md §14): a write-once file under `notebooks/`
/// that declares notebooks (`add`) and ends earlier records (`remove`), so
/// that a notebook no note names (just created, or emptied) still exists.
public struct NotebookRecord: Hashable, Sendable {
    /// The record's id: its file is `notebooks/<id>.notebook.age`.
    public var id: UUID
    /// When it was written (informational).
    public var created: Date?
    /// Canonical notebook paths it declares.
    public var add: [String]
    /// Ids of the records it ends.
    public var remove: [UUID]

    public init(id: UUID = UUID(), created: Date? = nil, add: [String] = [], remove: [UUID] = []) {
        self.id = id; self.created = created; self.add = add; self.remove = remove
    }

    /// Its file name, `<id>.notebook.age`.
    public var fileName: String { NotebookRecords.fileName(id) }
}

/// Errors reading a notebook record (format.md §14); each skips that record only.
public enum NotebookRecordError: Error, Hashable, Sendable {
    /// Larger than `NotebookRecords.maxFileBytes` (on disk or after gunzip).
    case tooLarge
    /// The age layer does not decrypt with this device's identities.
    case undecryptable(String)
    /// The body framing or tag does not check (format.md §4).
    case framing(BodyFramingError)
    /// Not a record: bad gzip or JSON, another `format`, a broken limit.
    case invalid(String)
    /// Under an earlier epoch's key and not taken by the acceptance rule (key-hierarchy design §5.3).
    case setAside(SetAsideReason)
    /// Under a key whose epoch record has not arrived (design §5.3 rule 3).
    case pending
}

/// The rules of notebook records (format.md §14): names, limits, the JSON,
/// and the observed-remove set they form. Pure logic; `Vault` reads and
/// writes the files.
public enum NotebookRecords {
    /// The vault folder holding records.
    public static let folderName = "notebooks"
    /// The label in the body tag in place of a note id (format.md §14.1).
    public static let tagScope = "notebooks"
    /// The `format` of this version's records.
    public static let formatName = "sempere-notebooks/1"
    /// Largest record, on disk and after gunzip (format.md §9).
    public static let maxFileBytes = 64 << 10
    /// Most `add` paths in one record.
    public static let maxAdds = 256
    /// Most `remove` ids in one record.
    public static let maxRemoves = 4096
    /// Longest path, in Unicode scalars.
    public static let maxPathScalars = 1200
    /// Most records read per vault; the rest are ignored and reported.
    public static let maxRecords = 10_000

    /// `<id>.notebook.age`.
    public static func fileName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).notebook.age" }

    /// The record id of a file name; nil for any other name (ignored).
    public static func id(ofFileName name: String) -> UUID? {
        let suffix = ".notebook.age"
        guard name.hasSuffix(suffix) else { return nil }
        let stem = String(name.dropLast(suffix.count))
        guard stem.count == 36, stem == stem.lowercased(), let id = UUID(uuidString: stem) else { return nil }
        return id
    }

    // MARK: JSON

    /// The record's JSON (format.md §14.2), keys sorted.
    public static func encode(_ record: NotebookRecord) throws -> Data {
        var root: [String: JSONValue] = ["format": .string(formatName)]
        if let created = record.created, let s = RFC3339.string(from: created) { root["created"] = .string(s) }
        if !record.add.isEmpty { root["add"] = .array(record.add.map(JSONValue.string)) }
        if !record.remove.isEmpty { root["remove"] = .array(record.remove.map { .string($0.uuidString.lowercased()) }) }
        return try InkJSON.encoder().encode(JSONValue.object(root))
    }

    /// Decodes a record's JSON for the record `id` (its file name's).
    ///
    /// - Throws: `NotebookRecordError.invalid` for anything but a record of
    ///   this format within the limits.
    public static func decode(_ json: Data, id: UUID) throws -> NotebookRecord {
        let root: JSONValue
        do { root = try InkJSON.decoder().decode(JSONValue.self, from: json) } catch {
            throw NotebookRecordError.invalid("not JSON")
        }
        guard case .object(let o) = root else { throw NotebookRecordError.invalid("not a JSON object") }
        guard case .string(formatName)? = o["format"] else { throw NotebookRecordError.invalid("format is not \(formatName)") }
        var record = NotebookRecord(id: id)
        if case .string(let s)? = o["created"] { record.created = RFC3339.parse(s) }
        switch o["add"] {
        case nil, .null?: break
        case .array(let items)?:
            guard items.count <= maxAdds else { throw NotebookRecordError.invalid("more than \(maxAdds) add paths") }
            for item in items {
                guard case .string(let path) = item else { throw NotebookRecordError.invalid("an add path is not a string") }
                guard path.unicodeScalars.count <= maxPathScalars else { throw NotebookRecordError.invalid("an add path is too long") }
                if let c = NotebookPath.canonical(path), !record.add.contains(c) { record.add.append(c) }
            }
        default: throw NotebookRecordError.invalid("add is not an array")
        }
        switch o["remove"] {
        case nil, .null?: break
        case .array(let items)?:
            guard items.count <= maxRemoves else { throw NotebookRecordError.invalid("more than \(maxRemoves) remove ids") }
            for item in items {
                guard case .string(let s) = item, s.count == 36, let r = UUID(uuidString: s) else {
                    throw NotebookRecordError.invalid("a remove id is not a UUID")
                }
                if r != id, !record.remove.contains(r) { record.remove.append(r) }
            }
        default: throw NotebookRecordError.invalid("remove is not an array")
        }
        return record
    }

    // MARK: The set (format.md §14.3, §14.4)

    /// The records no record ends.
    public static func live(_ records: [NotebookRecord]) -> [NotebookRecord] {
        let ended = Set(records.flatMap(\.remove))
        return records.filter { !ended.contains($0.id) }
    }

    /// The declared notebooks: canonical paths added by live records, sorted
    /// as the sidebar sorts them, without duplicates.
    public static func declared(_ records: [NotebookRecord]) -> [String] {
        let paths = Set(live(records).flatMap(\.add))
        return paths.sorted { NotebookNode.ascending($0, $1) }
    }

    /// The record that creates `path`, nil when it is declared already or names no notebook.
    public static func create(_ path: String, records: [NotebookRecord], now: Date) -> NotebookRecord? {
        guard let p = NotebookPath.canonical(path), !declared(records).contains(p) else { return nil }
        return NotebookRecord(created: now, add: [p])
    }

    /// The record that renames or moves `old` (and everything below it) to
    /// `new` (nil: the top level, `NotebookPath.renamed`): it ends every live
    /// record adding a path within `old` and adds their paths again, renamed
    /// or unchanged. Nil when no live record adds a path within `old`.
    public static func rename(_ old: String, to new: String?, records: [NotebookRecord], now: Date) -> NotebookRecord? {
        guard let o = NotebookPath.canonical(old) else { return nil }
        let affected = live(records).filter { r in r.add.contains { NotebookPath.name($0, isWithin: o) } }
        guard !affected.isEmpty else { return nil }
        var add: [String] = []
        for path in affected.flatMap(\.add) {
            guard let renamed = NotebookPath.canonical(NotebookPath.renamed(path, from: o, to: new)) else { continue }
            if !add.contains(renamed) { add.append(renamed) }
        }
        return NotebookRecord(created: now, add: add, remove: affected.map(\.id))
    }

    /// The record that deletes `path` and every notebook below it: it ends
    /// every live record adding a path within it and adds their other paths
    /// again. Nil when no live record adds a path within `path`.
    public static func delete(_ path: String, records: [NotebookRecord], now: Date) -> NotebookRecord? {
        guard let p = NotebookPath.canonical(path) else { return nil }
        let affected = live(records).filter { r in r.add.contains { NotebookPath.name($0, isWithin: p) } }
        guard !affected.isEmpty else { return nil }
        var add: [String] = []
        for other in affected.flatMap(\.add) where !NotebookPath.name(other, isWithin: p) && !add.contains(other) {
            add.append(other)
        }
        return NotebookRecord(created: now, add: add, remove: affected.map(\.id))
    }

    /// Every notebook to show (format.md §14.3): those `noteNotebooks` name
    /// and the declared ones, as one tree.
    public static func tree(noteNotebooks: [String?], declared: [String]) -> [NotebookNode] {
        NotebookNode.tree(noteNotebooks + declared.map { Optional($0) })
    }
}

/// The notebook records of a vault as read (`Vault.readNotebookRecords`).
public struct NotebookRecordSet: Hashable, Sendable {
    /// Every record read, by file name order.
    public var records: [NotebookRecord] = []
    /// Records that could not be read, by path (`notebooks/<name>`), with why.
    public var problems: [String: String] = [:]
    /// File names listed but not read (beyond `NotebookRecords.maxRecords`).
    public var ignored = 0

    public init(records: [NotebookRecord] = [], problems: [String: String] = [:], ignored: Int = 0) {
        self.records = records; self.problems = problems; self.ignored = ignored
    }

    /// The declared notebooks (format.md §14.3).
    public var declared: [String] { NotebookRecords.declared(records) }
}

extension Vault {
    /// `notebooks/` of this vault.
    public var notebooksURL: URL { url.appendingPathComponent(NotebookRecords.folderName, isDirectory: true) }

    /// The record file names under `notebooks/`, sorted; others are ignored.
    public func notebookRecordNames() throws -> [String] {
        try FileIO.entries(notebooksURL, directories: false) { NotebookRecords.id(ofFileName: $0) != nil }
    }

    /// Reads every notebook record (format.md §14). A record that cannot be
    /// read is skipped and listed in `problems`, never thrown.
    ///
    /// - Throws: `VaultError.locked`, `.noIdentities`; `VaultError.io` when
    ///   `notebooks/` exists but cannot be listed.
    public func readNotebookRecords() throws -> NotebookRecordSet {
        _ = try requireReadable()
        var set = NotebookRecordSet()
        let names = try notebookRecordNames()
        set.ignored = max(0, names.count - NotebookRecords.maxRecords)
        for name in names.prefix(NotebookRecords.maxRecords) {
            let path = "\(NotebookRecords.folderName)/\(name)"
            do {
                let data = try readFile(notebooksURL.appendingPathComponent(name), maxBytes: NotebookRecords.maxFileBytes)
                set.records.append(try openNotebookRecord(data, fileName: name))
            } catch VaultError.fileTooLarge {
                set.problems[path] = "\(NotebookRecordError.tooLarge)"
            } catch {
                set.problems[path] = "\(error)"
            }
        }
        return set
    }

    /// Decrypts, verifies and decodes the bytes of the record `fileName`
    /// (a file of this vault, or a copy from a sync server).
    public func openNotebookRecord(_ data: Data, fileName: String) throws -> NotebookRecord {
        let secret = try requireReadable()
        guard let id = NotebookRecords.id(ofFileName: fileName) else { throw NotebookRecordError.invalid("not a record name") }
        guard data.count <= NotebookRecords.maxFileBytes else { throw NotebookRecordError.tooLarge }
        _ = secret
        let plain: Data, key: VaultEpochKey, older: OlderEpoch?
        switch openUnderEpochs(data) {
        case .opened(let p, let k, let o): plain = p; key = k; older = o
        case .pending: throw NotebookRecordError.pending
        case .undecryptable(let why): throw NotebookRecordError.undecryptable(why)
        }
        let unframed: BodyFraming.Unframed
        do { unframed = try unframeNotebookRecord(plain, fileName: fileName, secret: key) } catch let e as BodyFramingError {
            throw NotebookRecordError.framing(e)
        }
        // Key-hierarchy design §5.3: under an earlier key only when sealed with these bytes.
        if let reason = setAsideReason(older, path: "\(NotebookRecords.folderName)/\(fileName)", sha256: FileDigest.sha256(data)) {
            throw NotebookRecordError.setAside(reason)
        }
        let json: Data
        do { json = try Gzip.decompress(unframed.gzip, maxOutput: NotebookRecords.maxFileBytes) } catch {
            throw NotebookRecordError.invalid("gzip")
        }
        return try NotebookRecords.decode(json, id: id)
    }

    private func unframeNotebookRecord(_ plain: Data, fileName: String, secret: VaultEpochKey) throws -> BodyFraming.Unframed {
        try BodyFraming.unframe(plain, noteId: NotebookRecords.tagScope, filename: fileName, secret: secret)
    }

    /// The bytes of `record`'s file (tagged under the vault secret, encrypted
    /// to its recipients).
    public func sealNotebookRecord(_ record: NotebookRecord) throws -> Data {
        let secret = try requireSecret()
        let body = try BodyFraming.frame(json: try NotebookRecords.encode(record), noteId: NotebookRecords.tagScope,
                                         filename: record.fileName, secret: secret)
        return try encrypt(body)
    }

    /// Writes `record` under its own name (write-once: an existing file is
    /// refused). A vault write (`requireWritable`).
    public func writeNotebookRecord(_ record: NotebookRecord) throws {
        try requireWritable()
        guard !record.add.isEmpty || !record.remove.isEmpty else { return }
        let data = try sealNotebookRecord(record)
        try FileManager.default.createDirectory(at: notebooksURL, withIntermediateDirectories: true)
        try recordWrite(path: "\(NotebookRecords.folderName)/\(record.fileName)", bytes: data)
        try FileIO.writeAtomically(data, to: notebooksURL.appendingPathComponent(record.fileName), replacing: false)
    }

    /// Declares the notebook `path` (format.md §14.4 "Create"). Returns the
    /// record written, nil when `path` is declared already.
    @discardableResult
    public func createNotebook(_ path: String, now: Date = Date()) throws -> NotebookRecord? {
        try requireWritable()
        guard let record = NotebookRecords.create(path, records: try readNotebookRecords().records, now: now) else { return nil }
        try writeNotebookRecord(record)
        return record
    }

    /// Renames the records of `old` and everything below it to `new` (nil:
    /// the top level), format.md §14.4. The notes are renamed separately
    /// (`NoteOps.renameNotebook`). Returns the record written, nil when no
    /// record declares a notebook within `old`.
    @discardableResult
    public func renameNotebookRecords(_ old: String, to new: String?, now: Date = Date()) throws -> NotebookRecord? {
        try requireWritable()
        guard let record = NotebookRecords.rename(old, to: new, records: try readNotebookRecords().records, now: now) else {
            return nil
        }
        try writeNotebookRecord(record)
        return record
    }

    /// Ends the records of `path` and everything below it (format.md §14.4
    /// "Delete"). Notes are not touched: callers delete only a notebook no
    /// live note is in. Returns the record written, nil when none declares it.
    @discardableResult
    public func deleteNotebookRecords(_ path: String, now: Date = Date()) throws -> NotebookRecord? {
        try requireWritable()
        guard let record = NotebookRecords.delete(path, records: try readNotebookRecords().records, now: now) else { return nil }
        try writeNotebookRecord(record)
        return record
    }
}
