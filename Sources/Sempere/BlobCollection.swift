import Age
import Foundation

// MARK: - Per-note inventory, collection and repair (docs/format.md §8.1.6)

/// A blob reference found in a revision (format.md §8.1.1). Found
/// structurally: any JSON object with a string `sha256` counts, inside item
/// kinds and fields this reader does not know too, so collection never
/// drops a blob that a newer writer's revision uses.
public struct FoundBlobReference: Hashable, Sendable {
    /// The `sha256` value as written (a valid reference has 64 lowercase hex digits).
    public var sha256: String
    /// The `type`, if the object has a string one.
    public var type: String?
    /// The `size`, if the object has an integral one.
    public var size: Int64?

    /// The file-name kind the reference resolves to (format.md §8.1.2).
    public var kind: BlobKind { BlobKind(mediaType: type ?? "") }

    /// The reference as a `BlobRef`, when it is well formed.
    public var ref: BlobRef? {
        guard let type, let size else { return nil }
        let r = BlobRef(sha256: sha256, size: size, type: type)
        return r.isValid ? r : nil
    }
}

/// The structural reference test of format.md §8.1.1 / §8.1.6.
enum BlobReferenceScan {
    /// Every object in `json` with a `sha256` key whose value is a string.
    static func references(in json: Data) throws -> [FoundBlobReference] {
        try facts(in: json).refs.map { FoundBlobReference(sha256: $0.sha256, type: $0.type, size: $0.size) }
    }

    /// The references with each one's holder hints (`duration`, `title` of
    /// the object holding the reference object) and the revision's
    /// top-level `wall`. Iterative, so nesting depth costs no stack
    /// (Foundation's parser caps it at 512 levels anyway).
    static func facts(in json: Data) throws -> AttachmentIndexEntry.RevisionFacts {
        let root = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        var refs: [AttachmentIndexEntry.Reference] = []
        var stack: [(value: Any, holder: [String: Any]?)] = [(root, nil)]
        while let top = stack.popLast() {
            let (value, holder) = top
            if let object = value as? [String: Any] {
                if let sha = object["sha256"] as? String {
                    var r = AttachmentIndexEntry.Reference(sha256: sha)
                    r.type = object["type"] as? String
                    r.size = integer(object["size"])
                    if let holder {
                        if let n = holder["duration"] as? NSNumber, String(cString: n.objCType) != "c",
                           n.doubleValue.isFinite, n.doubleValue >= 0 { r.duration = n.doubleValue }
                        if let t = holder["title"] as? String { r.title = String(t.prefix(AttachmentIndexer.maxTitle)) }
                    }
                    refs.append(r)
                }
                for v in object.values { stack.append((v, object)) }
            } else if let array = value as? [Any] {
                // An array's elements are held by whatever holds the array.
                for v in array { stack.append((v, holder)) }
            }
        }
        let wall = ((root as? [String: Any])?["wall"] as? String).flatMap(RFC3339.parse)
        return .init(refs: refs, wall: wall)
    }

    /// A JSON integer in `0...BlobRef.maxSize` (booleans and fractions refused).
    /// Booleans come back as NSNumber too, and `is Bool` is also true for 0
    /// and 1; their objCType is "c" (char), never a JSON integer's. Range-checked
    /// before conversion (format.md §9).
    static func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, String(cString: n.objCType) != "c" else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d <= Double(BlobRef.maxSize), d == d.rounded() else { return nil }
        return Int64(d)
    }
}

/// What a note's `att/` holds and what its revisions reference
/// (`Vault.blobInventory(note:)`). Reading it decrypts the note's revisions
/// but never a blob.
public struct BlobInventory: Hashable, Sendable {
    /// One blob file in `att/`.
    public struct File: Hashable, Sendable {
        /// `<name>.<kind>.age`.
        public var fileName: String
        public var kind: BlobKind
        /// Size on disk (encrypted, padded).
        public var bytes: Int64
        /// The content hash some reference of this note maps to this name
        /// (under the current secret, or the previous one during a rotation);
        /// nil when no reference does.
        public var sha256: String?
        /// True when a reference with that hash also has this file's kind:
        /// the file is what a lookup of that reference finds.
        public var resolvesReference: Bool
    }

    public var note: UUID
    /// Blob files, by name.
    public var files: [File] = []
    /// Other entries of `att/` (unknown files, never touched).
    public var unknownEntries: [String] = []
    /// The references each readable revision holds.
    public var references: [RevisionName: [FoundBlobReference]] = [:]
    /// Revisions that could not be read and verified.
    public var unreadable: [RevisionName: RevisionReadError] = [:]
    /// Why the note's folder or its `att/` could not be listed, if not.
    public var listingProblem: String?

    /// Every content hash referenced by a readable revision.
    public var referencedHashes: Set<String> { Set(references.values.joined().map(\.sha256)) }

    /// Rule 1 of format.md §8.1.6: everything was listed, read and verified.
    public var isComplete: Bool { listingProblem == nil && unreadable.isEmpty }

    /// Files that no reference maps to (by name; any kind).
    public var unreferenced: [File] { files.filter { $0.sha256 == nil } }

    /// Well-formed references (one per hash and kind) with no file to resolve to.
    public var missing: [BlobRef] {
        let present = Set(files.filter(\.resolvesReference).map { "\($0.sha256 ?? "")/\($0.kind.rawValue)" })
        var seen = Set<String>()
        var out: [BlobRef] = []
        for r in references.keys.sorted().flatMap({ references[$0] ?? [] }) {
            guard let ref = r.ref else { continue }
            let key = "\(ref.sha256)/\(ref.kind.rawValue)"
            if !present.contains(key) && seen.insert(key).inserted { out.append(ref) }
        }
        return out
    }
}

/// A device's own record of when it first found each unreferenced blob
/// collectable (format.md §8.1.6 rule 4). Never stored in the vault: the CLI
/// keeps it in `$XDG_STATE_HOME/sempere/blobs/<vaultId>.json`, the app in
/// Application Support.
public struct BlobCollectorState: Codable, Hashable, Sendable {
    /// The vault the state belongs to.
    public var vaultId: UUID?
    /// Note id (lowercase) → blob file name → when rules 1–3 were first
    /// found true for it, with every look since finding it unreferenced.
    public var notes: [String: [String: Date]]

    public init(vaultId: UUID? = nil) {
        self.vaultId = vaultId
        notes = [:]
    }

    /// The largest state file read.
    static let maxFileBytes = 64 << 20

    /// `$XDG_STATE_HOME/sempere/blobs/<vaultId>.json`, else
    /// `~/.local/state/sempere/blobs/<vaultId>.json`.
    public static func defaultURL(vaultId: UUID,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        DeviceState.defaultURL(environment: environment, home: home).deletingLastPathComponent()
            .appendingPathComponent("blobs").appendingPathComponent("\(vaultId.uuidString.lowercased()).json")
    }

    /// Reads the state file; a missing file is an empty state.
    ///
    /// - Throws: `VaultError.io` when it exists but cannot be read or parsed
    ///   (never silently reset: that would restart every window).
    public static func load(from url: URL, vaultId: UUID) throws -> BlobCollectorState {
        guard FileManager.default.fileExists(atPath: url.path) else { return BlobCollectorState(vaultId: vaultId) }
        do {
            let data = try BoundedRead.contents(of: url, maxBytes: maxFileBytes)
            var state = try InkJSON.decoder().decode(BlobCollectorState.self, from: data)
            if state.vaultId != vaultId { state = BlobCollectorState(vaultId: vaultId) }
            return state
        } catch {
            throw VaultError.io("blob collector state \(url.path): \(error)")
        }
    }

    /// Writes the state file atomically, creating its directory.
    public func save(to url: URL) throws {
        try FileIO.createDirectory(url.deletingLastPathComponent())
        try FileIO.writeAtomically(try InkJSON.encoder().encode(self), to: url, replacing: true)
    }
}

/// One unreferenced blob and where it stands in the retention window.
public struct UnusedBlob: Hashable, Sendable {
    public var fileName: String
    public var kind: BlobKind
    /// Size on disk.
    public var bytes: Int64
    /// When this device first found it collectable.
    public var firstSeen: Date
    /// When it may be deleted (`firstSeen` + retention).
    public var deletableFrom: Date
}

/// What `Vault.collectBlobs` found and did in one note.
public struct BlobCollectionReport: Hashable, Sendable {
    public var note: UUID
    /// True when nothing was deleted on purpose (`dryRun`).
    public var dryRun: Bool
    /// Why rules 1–2 stop collection in this note; nil when they hold.
    public var blocked: String?
    /// Blob files some revision references.
    public var referenced = 0
    /// Unreferenced blobs, deleted or not (in a dry run, those past the
    /// window are what would be deleted).
    public var unused: [UnusedBlob] = []
    /// File names deleted (dry run: that would be deleted).
    public var deleted: [String] = []
    /// Unreferenced blob files that could not be decrypted or verified:
    /// never deleted, reported (format.md §8.1.6).
    public var failures: [String: String] = [:]
}

/// What `Vault.repairBlobs` did in one note.
public struct BlobRepairReport: Hashable, Sendable {
    public var note: UUID
    /// Why nothing was attempted (a pending recipient change), if so.
    public var blocked: String?
    /// Old file name → the file name(s) it was rewritten as.
    public var repaired: [String: [String]] = [:]
    /// Blob files whose name does not verify and whose content no revision
    /// of the note references: left untouched (repair never launders an
    /// unreferenced file).
    public var leftAlone: [String] = []
    /// Files that could not be read or rewritten, with the reason.
    public var failures: [String: String] = [:]
}

extension Vault {
    /// The blobs of one note and the references to them (format.md §8.1.6).
    /// Reads and verifies every revision of the note (tags under the current
    /// and, during a rotation, the previous secret) and lists `att/`; no
    /// other note is read and no blob is decrypted.
    ///
    /// - Throws: `VaultError.locked` / `.noIdentities` / `.legacyVault`.
    ///   Unreadable revisions and listing failures are recorded, not thrown.
    public func blobInventory(note: UUID) throws -> BlobInventory {
        try requireMigrated()
        let secret = try requireReadable()
        var inv = BlobInventory(note: note)
        let noteName = note.uuidString.lowercased()
        let dir = noteURL(note)
        var names: [RevisionName] = []
        do { names = try revisionNames(of: note) } catch { inv.listingProblem = "\(error)" }
        for n in names {
            do {
                let data: Data
                do { data = try FileIO.read(dir.appendingPathComponent(n.filename), maxBytes: BoundedRead.maxRevisionBytes) } catch {
                    throw RevisionReadError.unreadable("\(error)")
                }
                let json = try revisionJSON(data, note: noteName, name: n, secret: secret)
                if RevisionMarkers.peekNewer(json) { noteNewerContent(in: note) }
                do { inv.references[n] = try BlobReferenceScan.references(in: json) } catch {
                    throw RevisionReadError.undecodable("\(error)")
                }
            } catch let e as RevisionReadError {
                if case .newer = e { noteNewerContent(in: note) }
                inv.unreadable[n] = e
            }
        }
        // Name → hash for every referenced hash, under each accepted secret.
        var byName: [String: String] = [:]
        var kinds: [String: Set<BlobKind>] = [:]
        for r in inv.references.values.joined() {
            guard let digest = Hex.decode(r.sha256) else { continue }
            kinds[r.sha256, default: []].insert(r.kind)
            for s in blobSecrets { byName[BlobName.name(digest: digest, secret: s)] = r.sha256 }
        }
        let att = attURL(note)
        let entries: [String]
        do { entries = try FileIO.entries(att) } catch {
            inv.listingProblem = inv.listingProblem ?? "\(error)"
            return inv
        }
        for e in entries {
            let url = att.appendingPathComponent(e)
            guard let parsed = BlobName.parse(e), !FileIO.isDirectory(url) else {
                if !e.hasPrefix(FileIO.tempPrefix) { inv.unknownEntries.append(e) }
                continue
            }
            let bytes = FileIO.size(url) ?? 0
            let sha = byName[parsed.name]
            inv.files.append(.init(fileName: e, kind: parsed.kind, bytes: bytes, sha256: sha,
                                   resolvesReference: sha.map { kinds[$0]?.contains(parsed.kind) == true } ?? false))
        }
        return inv
    }

    /// Collects the blobs of one note (format.md §8.1.6). A blob file is
    /// deleted only when
    ///
    /// 1. every revision of the note was listed, read and verified,
    /// 2. no `rewrap-journal.json` exists,
    /// 3. no revision of the note references its content hash (structurally,
    ///    in any kind or field, deleted notes included), and
    /// 4. this device found 1–3 true for it at least `retention` ago and
    ///    every time it looked since (recorded in `state`, never the vault).
    ///
    /// Before deleting, the blob is decrypted and verified in full (framing,
    /// padding, content hash, name under the current secret); a blob that
    /// fails is reported, never deleted. When rule 1 or 2 fails the note's records in `state` are
    /// dropped (its window restarts: nothing was found unreferenced).
    /// No other note is read.
    ///
    /// - Parameter dryRun: deletes nothing (`state` is still updated; the
    ///   caller decides whether to save it).
    public func collectBlobs(note: UUID, state: inout BlobCollectorState, now: Date = Date(),
                             retention: TimeInterval = CompactionPlanner.defaultRetention,
                             dryRun: Bool = false) throws -> BlobCollectionReport {
        let key = note.uuidString.lowercased()
        if state.vaultId != vaultId { state = BlobCollectorState(vaultId: vaultId) }
        var records = state.notes[key] ?? [:]
        defer { state.notes[key] = records.isEmpty ? nil : records }
        return try collectBlobs(note: note, records: &records, now: now, retention: retention, dryRun: dryRun)
    }

    /// `collectBlobs(note:state:…)` with the note's rule-4 records kept by
    /// the caller (blob file name → first seen unreferenced; the app keeps
    /// them in its attachment index, `AttachmentIndexEntry.unusedSince`).
    ///
    /// - Parameter only: when given, only these blob file names may be
    ///   deleted (Settings' per-item Delete); every unreferenced file is
    ///   still recorded and reported.
    public func collectBlobs(note: UUID, records: inout [String: Date], only: Set<String>? = nil, now: Date = Date(),
                             retention: TimeInterval = CompactionPlanner.defaultRetention,
                             dryRun: Bool = false) throws -> BlobCollectionReport {
        var report = BlobCollectionReport(note: note, dryRun: dryRun)
        if !dryRun { try requireWritable() }
        guard !pendingRewrap else {
            report.blocked = "a recipient change is unfinished (rule 2): run `sempere vault rewrap-resume`"
            records = [:]
            return report
        }
        let inv = try blobInventory(note: note)
        // The inventory may have found newer revisions (format.md §7.3).
        if !dryRun { try requireWritable() }
        guard inv.isComplete else {
            let names = inv.unreadable.keys.sorted().map(\.filename)
            report.blocked = inv.listingProblem.map { "cannot list the note (rule 1): \($0)" }
                ?? "unreadable revision(s) (rule 1): \(names.joined(separator: ", "))"
            records = [:]
            return report
        }
        let secret = try requireSecret()
        let referenced = inv.referencedHashes
        report.referenced = inv.files.count - inv.unreferenced.count
        var kept = BlobRetention.observe(unreferenced: inv.unreferenced.map(\.fileName), records: records, now: now)
        for file in inv.unreferenced {
            let first = kept[file.fileName] ?? now
            let entry = UnusedBlob(fileName: file.fileName, kind: file.kind, bytes: file.bytes, firstSeen: first,
                                   deletableFrom: BlobRetention.deletableFrom(first, retention: retention))
            report.unused.append(entry)
            guard now >= entry.deletableFrom, only?.contains(file.fileName) ?? true else { continue }
            // Only a blob that verifies in full (every chunk, framing, hash,
            // a name under the current secret) is ever deleted, and rule 3
            // is checked once more against the hash in its own header.
            let url = attURL(note).appendingPathComponent(file.fileName)
            do {
                let (header, _) = try Self.readBlobFile(url, identities: identities, secrets: [secret], expected: nil,
                                                        maxContent: BlobRef.maxSize)
                guard !referenced.contains(header.sha256) else { continue }
            } catch {
                report.failures[file.fileName] = "\(error)"
                continue
            }
            if !dryRun {
                try FileIO.remove(url)
                kept[file.fileName] = nil
            }
            report.deleted.append(file.fileName)
        }
        records = kept
        return report
    }

    /// Repairs the blobs of one note whose name does not verify under the
    /// current secret, or whose header is not encrypted to exactly the
    /// current recipients, or whose kind suffix does not match the
    /// references: what a recipient change by a build that predates blobs
    /// leaves (`docs/attachments.md` §3).
    ///
    /// Only blobs that are authentic are rewritten: either the name verifies
    /// under the current secret, or the content hash in the decrypted header
    /// is referenced by a verified revision of the note (whose tag binds that
    /// exact content). Each is fully verified and re-encrypted under a new
    /// file key to the current recipients, under the name and kind its
    /// references expect, then the old file is deleted. Anything else is left
    /// untouched and listed. Nothing happens while a recipient change is
    /// pending (`rewrap-resume` handles that case).
    public func repairBlobs(note: UUID) throws -> BlobRepairReport {
        try requireWritable()
        var report = BlobRepairReport(note: note)
        guard !pendingRewrap else {
            report.blocked = "a recipient change is unfinished: run `sempere vault rewrap-resume` first"
            return report
        }
        let inv = try blobInventory(note: note)
        // The inventory may have found newer revisions (format.md §7.3): it
        // set the read-only latch, so nothing is renamed or deleted.
        try requireWritable()
        let secret = try requireSecret()
        let recipients = try ageRecipients()
        let expected = Self.expectedStanzas(recipients)
        var refsByHash: [String: [BlobRef]] = [:]
        for r in inv.references.values.joined() {
            if let ref = r.ref, !(refsByHash[ref.sha256] ?? []).contains(where: { $0.kind == ref.kind }) {
                refsByHash[ref.sha256, default: []].append(ref)
            }
        }
        let att = attURL(note)
        for file in inv.files {
            let url = att.appendingPathComponent(file.fileName)
            let peek: BlobPeek
            do { peek = try Self.peekBlobFile(url, identities: identities) } catch {
                report.failures[file.fileName] = "\(error)"; continue
            }
            let name = BlobName.parse(file.fileName)?.name ?? ""
            let nameOK = BlobName.verify(name, digest: peek.header.digest, secrets: [secret]) != nil
            let refs = refsByHash[peek.header.sha256] ?? []
            let kindOK = refs.isEmpty || refs.contains { $0.kind == file.kind }
            if nameOK && kindOK && peek.stanzas == expected { continue }
            // Targets: the kinds the references expect; an authentic blob no
            // reference uses keeps its own kind.
            let kinds = refs.isEmpty ? [file.kind] : refs.map(\.kind)
            guard nameOK || !refs.isEmpty else { report.leftAlone.append(file.fileName); continue }
            let currentName = BlobName.name(digest: peek.header.digest, secret: secret)
            var written: [String] = []
            do {
                for kind in kinds {
                    let targetName = BlobName.fileName(name: currentName, kind: kind)
                    let target = att.appendingPathComponent(targetName)
                    if target != url, FileIO.exists(target),
                       isCompleteBlob(target, header: peek.header, stanzas: expected, secret: secret) {
                        written.append(targetName); continue
                    }
                    let tmp = FileIO.tempURL(in: att)
                    var checker = BlobPlaintextChecker(expected: refs.first)
                    do {
                        try AgeFile.reencrypt(contentsOf: url, to: tmp, identities: identities, recipients: recipients,
                                              allowMixedPostQuantum: true, inspect: { try checker.consume($0) })
                        guard try checker.finish() == peek.header else { throw BlobError.contentHashMismatch }
                    } catch {
                        try? FileManager.default.removeItem(at: tmp)
                        throw error
                    }
                    try FileIO.place(tmp, at: target)
                    written.append(targetName)
                }
            } catch {
                report.failures[file.fileName] = "\(error)"; continue
            }
            if !written.contains(file.fileName) { try FileIO.remove(url) }
            report.repaired[file.fileName] = written
        }
        return report
    }
}
