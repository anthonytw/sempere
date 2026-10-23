import Age
import Foundation

/// One row of a note's history, for a UI.
public struct HistoryEntry: Hashable, Sendable {
    /// The revision file name.
    public var name: RevisionName
    /// The revision's `wall` time; nil when the file could not be read.
    public var wall: Date?
    /// The revision's `app` field; nil when the file could not be read.
    public var app: String?
    /// Why the file could not be read, if it could not.
    public var error: RevisionReadError?
}

/// How much of a revision to decode.
public enum RevisionDetail: Hashable, Sendable {
    /// Everything.
    case full
    /// Everything but stroke geometry: every stroke's `points` is empty
    /// (`StrokePointsFilter`). Ids, inks, transforms, origins, pages, metadata,
    /// tags and recognition are decoded and checked exactly as in `.full`, so
    /// `NoteReducer` gives the same pages, strokes and metadata. For listings
    /// and search; such revisions must never be written, snapshotted,
    /// rendered or diffed. One exception: a state merged from them may feed a
    /// write of metadata-only ops (meta, tags, delete/restore), built from
    /// `meta`, `tagSet` and `deleted` alone; the app's `NoteWriter` re-runs a
    /// builder on the full note if it returns any other op. Their names,
    /// readings and snapshot `included` may also feed a writer's readings and
    /// `seq` (`Vault.writeReadings`).
    case withoutStrokePoints
}

/// Revisions of one note loaded leniently: what could be read, and why the
/// rest could not.
public struct LoadedNote: Hashable, Sendable {
    /// Readable, verified revisions, sorted by `(hlc, device, seq)`.
    public var revisions: [Revision]
    /// Every listed revision that failed to read.
    public var failures: [RevisionName: RevisionReadError]

    /// What this note holds that a newer version wrote (format.md §7.4):
    /// newer revisions read leniently, and those not readable at all. Nil
    /// when there is none; the vault is then read-only (§7.3).
    public var newer: NewerContent? {
        var out = NewerContent()
        for r in revisions { if let n = r.newer { out.merge(n) } }
        for e in failures.values { if case .newer = e { out.unreadable = NewerContent.add(out.unreadable, 1) } }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Note store (format.md §5)

extension Vault {
    /// True for a backup folder (it holds `backup.json`): untrusted storage a
    /// symbolic link may have been planted in, so the vault's files are read
    /// without following any link below the folder (format.md §9, security
    /// review S3). A live vault follows links (users link folders into it).
    var readsWithoutLinks: Bool { Self.readsWithoutLinks(url) }

    static func readsWithoutLinks(_ root: URL) -> Bool {
        FileIO.exists(root.appendingPathComponent(BackupManifest.fileName))
    }

    /// `path` relative to the vault folder, nil outside it.
    private func relativePath(_ file: URL) -> String? {
        let base = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return file.path.hasPrefix(base) ? String(file.path.dropFirst(base.count)) : nil
    }

    /// Reads a file of the vault (`FileIO.read`), refusing symbolic links in a backup folder.
    func readFile(_ file: URL, maxBytes: Int) throws -> Data {
        if readsWithoutLinks, let rel = relativePath(file) {
            return try BoundedRead.contents(under: url, rel, maxBytes: maxBytes)
        }
        return try FileIO.read(file, maxBytes: maxBytes)
    }

    /// Opens a file of the vault for reading, refusing symbolic links in a backup folder.
    func openFile(_ file: URL) throws -> FileHandle {
        if readsWithoutLinks, let rel = relativePath(file) { return try BoundedRead.openRegularFile(under: url, rel) }
        return try BoundedRead.openRegularFile(file)
    }

    /// Note ids: the lowercase-UUID directories under `notes/`, sorted.
    /// Anything else there is ignored.
    ///
    /// - Throws: `VaultError.io` if `notes/` exists but cannot be listed.
    public func noteIDs() throws -> [UUID] {
        try noteDirectoryNames().compactMap(UUID.init(uuidString:))
    }

    /// Revision file names of a note, sorted by `(hlc, device, seq)`.
    /// Unknown files and directories are ignored; a note without a
    /// directory has none.
    ///
    /// - Throws: `VaultError.io` if the note directory cannot be listed.
    public func revisionNames(of noteId: UUID) throws -> [RevisionName] {
        try revisionFileNames(in: noteURL(noteId)).compactMap(RevisionName.init).sorted()
    }

    /// The bytes the note's revision files take on disk, or nil when one cannot be measured
    /// (not downloaded yet, unreadable). An exporter sizes what reading the note will cost
    /// from it, before it reads (decoded, a note is several times larger).
    public func revisionBytes(of noteId: UUID) -> Int? {
        let dir = noteURL(noteId)
        guard let names = try? revisionFileNames(in: dir) else { return nil }
        var total = 0
        for name in names {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? NSNumber
            else { return nil }
            total += size.intValue
        }
        return total
    }

    func noteURL(_ noteId: UUID) -> URL {
        notesURL.appendingPathComponent(noteId.uuidString.lowercased())
    }

    /// Reads one revision: age-decrypts it, checks magic, version and tag,
    /// gunzips and decodes it, and checks that the content names this note
    /// and file.
    ///
    /// - Throws: `VaultError.locked` or `.noIdentities` when the vault cannot
    ///   read at all; otherwise `RevisionReadError`, one case per failing stage.
    public func readRevision(noteId: UUID, name: RevisionName, detail: RevisionDetail = .full) throws -> Revision {
        try decodeVerifiedRevision(try readRevisionJSON(noteId: noteId, name: name), noteId: noteId, name: name,
                                   detail: detail)
    }

    /// The first half of `readRevision`: the file read, decrypted, verified
    /// and gunzipped, not yet decoded (`decodeVerifiedRevision`), so a
    /// caller can decode it at two levels of detail without decrypting it twice.
    func readRevisionJSON(noteId: UUID, name: RevisionName) throws -> Data {
        let secret = try requireReadable()
        let data: Data
        do {
            data = try readFile(noteURL(noteId).appendingPathComponent(name.filename), maxBytes: BoundedRead.maxRevisionBytes)
        } catch {
            throw RevisionReadError.unreadable("\(error)")
        }
        do {
            return try revisionJSON(data, note: noteId.uuidString.lowercased(), name: name, secret: secret)
        } catch RevisionReadError.newer(let why) {
            // Seen, if not read: the vault is read-only from now on (format.md §7.3).
            noteNewerContent(in: noteId)
            throw RevisionReadError.newer(why)
        }
    }

    /// The second half of `readRevision`: decodes what `readRevisionJSON` returned.
    func decodeVerifiedRevision(_ json: Data, noteId: UUID, name: RevisionName, detail: RevisionDetail) throws -> Revision {
        do {
            let rev = try Self.decodeRevisionJSON(json, note: noteId.uuidString.lowercased(), name: name, detail: detail)
            if rev.newer != nil { noteNewerContent(in: rev.noteId) }
            return rev
        } catch RevisionReadError.newer(let why) {
            noteNewerContent(in: noteId)
            throw RevisionReadError.newer(why)
        }
    }

    func decodeRevisionFile(_ data: Data, note: String, name: RevisionName, secret: VaultEpochKey,
                            detail: RevisionDetail = .full) throws -> Revision {
        do {
            let json = try revisionJSON(data, note: note, name: name, secret: secret)
            let rev = try Self.decodeRevisionJSON(json, note: note, name: name, detail: detail)
            if rev.newer != nil { noteNewerContent(in: rev.noteId) }
            return rev
        } catch RevisionReadError.newer(let why) {
            // Seen, if not read: the vault is read-only from now on (format.md §7.3).
            if let id = UUID(uuidString: note) { noteNewerContent(in: id) }
            throw RevisionReadError.newer(why)
        }
    }

    /// Decrypts a revision file, verifies its tag (format.md §4) and gunzips it.
    ///
    /// - Throws: `RevisionReadError`, one case per failing stage.
    ///
    /// Under the acceptance rule (key-hierarchy design §5.3): a file that decrypts under the current key is
    /// taken; one under an earlier key of the chain only when the record that closed that epoch seals this
    /// path with exactly these bytes, else it is set aside (`RevisionReadError.setAside`); one that no key
    /// opens while a record on the chain is missing is pending. `secret` is the current key.
    func revisionJSON(_ data: Data, note: String, name: RevisionName, secret: VaultEpochKey, accepting: Bool = true) throws -> Data {
        revisionDecrypts.add()
        let plain: Data, key: VaultEpochKey, older: OlderEpoch?
        switch openUnderEpochs(data) {
        case .opened(let p, let k, let o): plain = p; key = k; older = o
        case .pending: throw RevisionReadError.pending
        case .undecryptable(let why): throw RevisionReadError.undecryptable(why)
        }
        let unframed: BodyFraming.Unframed
        do {
            unframed = try BodyFraming.unframe(plain, noteId: note, filename: name.filename, secret: key)
        } catch BodyFramingError.unsupportedVersion(let v) where v > SempereFormat.bodyVersion {
            throw RevisionReadError.newer("body version \(v)")
        } catch BodyFramingError.tagMismatch {
            throw RevisionReadError.tagMismatch
        } catch {
            throw RevisionReadError.corruptBody("\(error)")
        }
        if accepting, let reason = setAsideReason(older, path: "\(Self.notesName)/\(note)/\(name.filename)",
                                       sha256: FileDigest.sha256(data)) {
            throw RevisionReadError.setAside(reason)
        }
        do { return try Gzip.decompress(unframed.gzip) } catch {
            throw RevisionReadError.corruptBody("\(error)")
        }
    }

    /// Decodes verified revision JSON and checks it names this note and file.
    static func decodeRevisionJSON(_ json: Data, note: String, name: RevisionName,
                                   detail: RevisionDetail) throws -> Revision {
        let rev: Revision
        do {
            rev = detail == .full ? try FastRevisionDecoder.decode(json)
                : try InkJSON.decoder().decode(Revision.self, from: StrokePointsFilter.strip(json))
        } catch {
            // A newer revision that does not decode is newer, not corrupt (format.md §7.2).
            if RevisionMarkers.peekNewer(json) { throw RevisionReadError.newer("\(error)") }
            throw RevisionReadError.undecodable("\(error)")
        }
        guard rev.noteId.uuidString.lowercased() == note, rev.name == name else {
            throw RevisionReadError.undecodable("content is \(rev.noteId.uuidString.lowercased())/\(rev.name.filename)")
        }
        return rev
    }

    /// Writes a revision: JSON, gzip, frame and tag, age-encrypt to the
    /// vault identity, then an atomic create of
    /// `notes/<noteId>/<name>`.
    ///
    /// - Throws: `VaultError.locked`, `.alreadyExists` if the file exists
    ///   (files under `notes/` are write-once), `.seqInUse` if another file of
    ///   this note already has the same `(device, seq)`, `.seqOutOfRange` for
    ///   a `seq` readers would reject.
    public func write(_ revision: Revision) throws {
        let secret = try requireSecret()
        try requireWritable()
        // A revision read leniently is approximate: never write it back (format.md §7.4).
        if revision.newer != nil { throw VaultError.readOnly(ReadOnlyReasons(newerNotes: [revision.noteId])) }
        guard (1...RevisionName.maxSeq).contains(revision.seq) else { throw VaultError.seqOutOfRange(revision.seq) }
        try writeEncoded(try encodedRevision(revision, secret: secret), of: revision)
    }

    /// The checks of `write` before anything is encoded.
    private func checkFree(_ revision: Revision) throws {
        let name = revision.name
        let file = noteURL(revision.noteId).appendingPathComponent(name.filename)
        guard !FileIO.exists(file) else { throw VaultError.alreadyExists(file.path) }
        if try revisionNames(of: revision.noteId).contains(where: { $0.device == name.device && $0.seq == name.seq }) {
            throw VaultError.seqInUse(device: name.device.rawValue, seq: name.seq)
        }
    }

    /// Stores `encrypted`, the output of `encodedRevision(revision)`, as
    /// `write` does (same checks, write-once).
    func writeEncoded(_ encrypted: Data, of revision: Revision) throws {
        try requireWritable()
        guard (1...RevisionName.maxSeq).contains(revision.seq) else { throw VaultError.seqOutOfRange(revision.seq) }
        try checkFree(revision)
        // A partial copy's note lacking revisions is never written to (format.md §1.2).
        try requireNoteComplete(revision.noteId)
        let dir = noteURL(revision.noteId)
        try FileIO.createDirectory(dir)
        try recordWrite(path: Self.notePath(revision.noteId, revision.name.filename), bytes: encrypted)
        try FileIO.writeAtomically(encrypted, to: dir.appendingPathComponent(revision.name.filename), replacing: false)
    }

    /// A revision as `write` stores it: JSON, gzip, frame and tag, encrypted
    /// to the current recipients.
    func encodedRevision(_ revision: Revision, secret: VaultEpochKey? = nil) throws -> Data {
        let secret = try secret ?? requireSecret()
        let json = try InkJSON.encoder().encode(revision)
        let body = try BodyFraming.frame(json: json, noteId: revision.noteId.uuidString.lowercased(),
                                         filename: revision.name.filename, secret: secret)
        return try encrypt(body)
    }

    /// The next `seq` for `device` in this note (format.md §5): one more than
    /// the largest seen in a file name or covered by any snapshot's
    /// `included`, so a device whose old revisions were compacted away never
    /// reuses a covered seq. Decrypts every snapshot of the note (and decodes
    /// it without stroke geometry: only `included` is used) and nothing else;
    /// callers that already hold all revisions should use `nextSeq(from:device:)`.
    ///
    /// A snapshot whose tag does not verify (`RevisionReadError.tagMismatch`)
    /// is skipped: no writer of the vault made it, so it covers nothing.
    ///
    /// - Throws: `VaultError.revision` when a snapshot cannot be read (its
    ///   coverage is unknown, so no safe seq can be chosen), `.locked` /
    ///   `.noIdentities` when snapshots exist but the vault cannot read.
    public func nextSeq(noteId: UUID, device: DeviceID) throws -> Int {
        let names = try revisionNames(of: noteId)
        var top = names.filter { $0.device == device }.map(\.seq).max() ?? 0
        for n in names where n.kind == .snapshot {
            let r: Revision
            do { r = try readRevision(noteId: noteId, name: n, detail: .withoutStrokePoints) } catch RevisionReadError.tagMismatch {
                // It decrypted with this vault's key but was not framed under
                // the vault's secret (nor the previous one of an unfinished
                // rotation, whose journal did read): written by someone who
                // only has the public keys, never by a writer of this vault,
                // so it covers nothing. Skipping it reuses no seq, and one
                // planted file no longer blocks every edit to the note
                // (format.md §5, security review 2026-10, W2). Any other
                // failure may hide real coverage and still throws.
                continue
            } catch RevisionReadError.setAside {
                // Set aside (key-hierarchy design §5.3), yet written by a holder of an earlier key, perhaps
                // this device before a catch-up: its coverage still counts, so no seq is reused.
                let data = try readFile(noteURL(noteId).appendingPathComponent(n.filename), maxBytes: BoundedRead.maxRevisionBytes)
                let json = try revisionJSON(data, note: noteId.uuidString.lowercased(), name: n, secret: try requireSecret(),
                                            accepting: false)
                r = try Self.decodeRevisionJSON(json, note: noteId.uuidString.lowercased(), name: n, detail: .withoutStrokePoints)
            } catch let e as RevisionReadError {
                throw VaultError.revision(name: n.filename, e)
            }
            top = max(top, Self.nextSeq(from: [r], device: device) - 1)
        }
        return top + 1
    }

    /// The next `seq` for `device` given **all** revisions of a note, without
    /// touching disk: one more than the largest `seq` of `device` among them
    /// or covered by any snapshot's `included`.
    public static func nextSeq(from revisions: [Revision], device: DeviceID) -> Int {
        var top = 0
        for r in revisions {
            if r.device == device { top = max(top, r.seq) }
            if case .snapshot(let included, _) = r.body, let e = included.entries[device] {
                top = max(top, e.upTo, e.extra.max() ?? 0)
            }
        }
        return top + 1
    }

    /// Reads every revision of a note, collecting failures instead of
    /// throwing on them.
    public func loadNote(_ noteId: UUID, detail: RevisionDetail = .full) throws -> LoadedNote {
        try loadNote(noteId, names: try revisionNames(of: noteId), detail: detail)
    }

    /// `loadNote` that takes the revisions in `known` (by file name, read
    /// earlier at the same `detail`) instead of reading them again: revision
    /// files are write-once, so a name holds the same content for as long as
    /// it is listed. Only names not in `known` are read; names no longer
    /// listed are left out, and a name that failed before is read again.
    public func loadNote(_ noteId: UUID, reusing known: [String: Revision],
                         detail: RevisionDetail = .full) throws -> LoadedNote {
        _ = try requireReadable()
        var revs: [Revision] = []
        var failures: [RevisionName: RevisionReadError] = [:]
        for n in try revisionNames(of: noteId) {
            if let r = known[n.filename], r.name == n {
                // As readRevision does for it: the vault is read-only from then on (format.md §7.3).
                if r.newer != nil { noteNewerContent(in: noteId) }
                revs.append(r)
                continue
            }
            do { revs.append(try readRevision(noteId: noteId, name: n, detail: detail)) } catch let e as RevisionReadError {
                failures[n] = e
            }
        }
        return LoadedNote(revisions: revs, failures: failures)
    }

    /// `loadNote` for names already listed (`revisionNames(of:)`).
    func loadNote(_ noteId: UUID, names: [RevisionName], detail: RevisionDetail) throws -> LoadedNote {
        _ = try requireReadable()
        var revs: [Revision] = []
        var failures: [RevisionName: RevisionReadError] = [:]
        for n in names {
            do { revs.append(try readRevision(noteId: noteId, name: n, detail: detail)) } catch let e as RevisionReadError {
                failures[n] = e
            }
        }
        return LoadedNote(revisions: revs, failures: failures)
    }

    /// `reconstruct(noteId:)` of each of `ids` (strict: any unreadable
    /// revision fails that note), on up to `maxConcurrency` threads (0: one
    /// per core, at most 8), in `ids` order. With `.withoutStrokePoints` the
    /// states have no stroke geometry: for search and listings only.
    public func states(of ids: [UUID], detail: RevisionDetail = .full,
                       maxConcurrency: Int = 0) -> [Result<NoteState, any Error>] {
        Parallel.map(ids, width: maxConcurrency > 0 ? maxConcurrency : Parallel.defaultWidth) { id in
            Result { try NoteReducer.reconstruct(Self.strictRevisions(of: try loadNote(id, detail: detail))) }
        }
    }

    /// Reconstructs a note from all its revisions (`NoteReducer`).
    ///
    /// - Throws: `VaultError.revision` for the first unreadable revision
    ///   (failures are reported, never silently dropped; use `loadNote` to
    ///   reconstruct from what is readable), or `NoteLogError`.
    public func reconstruct(noteId: UUID) throws -> NoteState {
        try NoteReducer.reconstruct(strictRevisions(noteId))
    }

    /// `reconstruct(noteId:)` for a note already loaded with `loadNote`, so
    /// it is not decrypted twice. Same strictness: any failure throws.
    public func reconstruct(_ loaded: LoadedNote) throws -> NoteState {
        try NoteReducer.reconstruct(Self.strictRevisions(of: loaded))
    }

    func strictRevisions(_ noteId: UUID) throws -> [Revision] {
        try Self.strictRevisions(of: try loadNote(noteId))
    }

    /// The readable revisions, or the first failure. A revision unreadable
    /// only because a newer version wrote it (`RevisionReadError.newer`) is
    /// left out instead (format.md §7.4): it is reported in `loaded.newer`,
    /// and the vault, having seen it, is read-only.
    static func strictRevisions(of loaded: LoadedNote) throws -> [Revision] {
        // Newer revisions are reported in `loaded.newer`; set-aside and pending ones are never placed in
        // the note (key-hierarchy design §5.3): neither fails the note.
        let failures = loaded.failures.filter {
            switch $0.value {
            case .newer, .setAside, .pending: return false
            default: return true
            }
        }
        if let (name, err) = failures.min(by: { $0.key < $1.key }) {
            throw VaultError.revision(name: name.filename, err)
        }
        return loaded.revisions
    }

    /// Writes a snapshot of every revision of the note (`SnapshotBuilder`),
    /// with the next free `seq` for `device`, and returns it.
    @discardableResult
    public func snapshot(noteId: UUID, device: DeviceID, clock: inout HybridClock, wall: Date,
                         app: String) throws -> Revision {
        try snapshot(loaded: try loadNote(noteId), device: device, clock: &clock, wall: wall, app: app)
    }

    /// `snapshot(noteId:...)` for a note already loaded with `loadNote`.
    @discardableResult
    public func snapshot(loaded: LoadedNote, device: DeviceID, clock: inout HybridClock, wall: Date,
                         app: String) throws -> Revision {
        let revs = try Self.strictRevisions(of: loaded)
        let seq = Self.nextSeq(from: revs, device: device)
        let snap = try SnapshotBuilder.makeSnapshot(from: revs, device: device, seq: seq, clock: &clock,
                                                    wall: wall, app: app)
        try write(snap)
        return snap
    }

    /// Deletes what `CompactionPlanner` allows (format.md §5.3) and nothing
    /// else. Nothing is deleted while a revision of the note cannot be read
    /// (its coverage is unknown, and so is whether a checkpoint is complete).
    ///
    /// - Returns: the deleted names.
    /// - Throws: `CompactionError.unreadableRevision`, as `planCompaction` does.
    @discardableResult
    public func compact(noteId: UUID, retention: TimeInterval = CompactionPlanner.defaultRetention,
                        now: Date = Date()) throws -> [RevisionName] {
        try compact(noteId: noteId, loaded: try loadNote(noteId), retention: retention, now: now)
    }

    /// `compact(noteId:...)` for a note already loaded with `loadNote`. The
    /// plan is made from `loaded`, so it must reflect what is on disk.
    @discardableResult
    public func compact(noteId: UUID, loaded: LoadedNote, retention: TimeInterval = CompactionPlanner.defaultRetention,
                        now: Date = Date()) throws -> [RevisionName] {
        // Deleting is writing: a vault with an unknown feature is read-only (format.md §2).
        try requireWritable()
        try requireNoteComplete(noteId)
        if let name = loaded.failures.keys.min() { throw CompactionError.unreadableRevision(name.filename) }
        let doomed = loaded.compactionPlan(retention: retention, now: now)
        let dir = noteURL(noteId)
        for n in doomed { try FileIO.remove(dir.appendingPathComponent(n.filename)) }
        return doomed
    }

    /// Every revision of a note with its wall time, oldest first by
    /// `(hlc, device, seq)`. Unreadable revisions are listed with their error.
    /// Stroke geometry is not decoded (`.withoutStrokePoints`): only `wall`
    /// and `app` are kept.
    public func history(noteId: UUID) throws -> [HistoryEntry] {
        _ = try requireReadable()
        return try revisionNames(of: noteId).map { n in
            do {
                let r = try readRevision(noteId: noteId, name: n, detail: .withoutStrokePoints)
                return HistoryEntry(name: n, wall: r.wall, app: r.app, error: nil)
            } catch let e as RevisionReadError {
                return HistoryEntry(name: n, wall: nil, app: nil, error: e)
            }
        }
    }
}
