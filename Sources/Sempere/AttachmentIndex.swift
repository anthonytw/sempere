import Foundation

// MARK: - The unused-attachments index (docs/attachments.md §4, format.md §8.1.6)
//
// Device-local facts about each note's attachment blobs: what `att/` holds,
// which revisions reference each blob, whether the note's current state still
// shows it, and since when this device has found it unreferenced (rule 4).
// One entry per note, updated one note at a time (`AttachmentIndexer.update`)
// from what changed: revisions are write-once, so the references of a
// revision already read are kept by file name and never decrypted again.
// The app keeps the entries sealed in Application Support
// (`AttachmentIndexStore`); the CLI computes them per run with its own
// `BlobCollectorState`. Both build `AttachmentStorageReport` from them, so
// they show the same numbers. Nothing here deletes: deletion is
// `Vault.collectBlobs`, which reads the whole note again.

/// What the attachment index reads from a vault, one note at a time. `Vault`
/// is one; tests wrap it to count what an update touches.
public protocol AttachmentIndexSource: Sendable {
    /// The revision file names of `note`, sorted (one listing of its folder).
    func revisionNames(of note: UUID) throws -> [RevisionName]
    /// The blob references of one revision (one decryption and verification).
    ///
    /// - Throws: `RevisionReadError` when it cannot be read and verified.
    func blobFacts(note: UUID, revision: RevisionName) throws -> AttachmentIndexEntry.RevisionFacts
    /// The blob files in the note's `att/` (one listing; none when it does not exist).
    func blobFiles(note: UUID) throws -> [AttachmentIndexEntry.Listed]
    /// The name stems content with this hash has under each accepted secret
    /// (format.md §8.1.2; two during an unfinished secret rotation).
    func blobNames(sha256: String) -> [String]
    /// True while a recipient change is unfinished (rule 2 of format.md §8.1.6).
    var pendingRewrap: Bool { get }
}

/// One note's entry in the attachment index.
public struct AttachmentIndexEntry: Codable, Hashable, Sendable {
    /// Bumped when the entry or how it is computed changes; an entry of
    /// another schema is ignored (its note is indexed again, its windows restart).
    public static let schemaVersion = 1

    /// A blob reference found in a revision, with what the object holding it
    /// says about it (a recording's `duration` and `title`), for the list.
    public struct Reference: Codable, Hashable, Sendable {
        public var sha256: String
        public var type: String?
        public var size: Int64?
        /// The holding item's `duration` (seconds), if it has a number one.
        public var duration: Double?
        /// The holding item's `title`, if it has a string one (at most 200 characters kept).
        public var title: String?

        public init(sha256: String, type: String? = nil, size: Int64? = nil, duration: Double? = nil, title: String? = nil) {
            self.sha256 = sha256; self.type = type; self.size = size; self.duration = duration; self.title = title
        }
    }

    /// The references of one readable revision and its `wall` time.
    public struct RevisionFacts: Codable, Hashable, Sendable {
        public var refs: [Reference]
        public var wall: Date?

        public init(refs: [Reference], wall: Date?) { self.refs = refs; self.wall = wall }
    }

    /// One blob file as listed in `att/`.
    public struct Listed: Hashable, Sendable {
        public var fileName: String
        public var kind: BlobKind
        /// Size on disk (encrypted, padded).
        public var bytes: Int64
        /// The keyed-hash part of the name.
        public var name: String

        public init(fileName: String, kind: BlobKind, bytes: Int64, name: String) {
            self.fileName = fileName; self.kind = kind; self.bytes = bytes; self.name = name
        }
    }

    /// The newest revision that referenced a blob, and what it said about it.
    public struct LastUse: Codable, Hashable, Sendable {
        /// Its file name (a restore point while it survives, format.md §5.7).
        public var revision: String
        public var wall: Date?
        public var type: String?
        public var size: Int64?
        public var duration: Double?
        public var title: String?

        public init(revision: String, wall: Date?, type: String?, size: Int64?, duration: Double?, title: String?) {
            self.revision = revision; self.wall = wall; self.type = type; self.size = size
            self.duration = duration; self.title = title
        }
    }

    /// One blob file of the note.
    public struct File: Codable, Hashable, Sendable {
        public var fileName: String
        public var kind: BlobKind
        public var bytes: Int64
        /// The content hash a readable revision maps this name to; nil when none does.
        public var sha256: String?
        /// Readable revisions that reference it (file names, oldest first).
        public var revisions: [String]
        /// The newest revision that referenced it, kept after that revision is gone.
        public var lastUse: LastUse?
    }

    public var schema = AttachmentIndexEntry.schemaVersion
    public var note: UUID
    /// The references of each readable revision, by file name (write-once,
    /// so never read again while the name stays).
    public var revisions: [String: RevisionFacts] = [:]
    /// Revisions that could not be read and verified, with the reason (read again next time).
    public var unreadable: [String: String] = [:]
    /// Why nothing could be decided for the note: a listing failed, a
    /// recipient change is unfinished, or (iCloud Drive) not every revision is
    /// on this device. Nil when the entry is complete as far as the listings go.
    public var problem: String?
    /// The blob files in `att/`, by name.
    public var files: [File] = []
    /// The hashes the note's current state references; nil when unknown.
    public var current: [String]?
    /// Rule 4's record: blob file name → when this device first found it
    /// unreferenced (with every look since finding it so). The same records
    /// `Vault.collectBlobs(note:records:)` keeps.
    public var unusedSince: [String: Date] = [:]
    /// When the entry was last updated.
    public var checked: Date?

    public init(note: UUID) { self.note = note }

    /// Every revision was listed, read and verified (rule 1), and no
    /// recipient change is unfinished (rule 2).
    public var isComplete: Bool { problem == nil && unreadable.isEmpty }

    /// Files no readable revision references; empty unless `isComplete`
    /// (an unread revision might hold the only reference).
    public var unused: [File] { isComplete ? files.filter { $0.sha256 == nil } : [] }

    /// Files some revision references but the current state does not: space
    /// held only by history, freed once compaction drops those revisions.
    public var heldByHistory: [File] {
        guard let current else { return [] }
        let shown = Set(current)
        return files.filter { $0.sha256.map { !shown.contains($0) } ?? false }
    }

    /// The revision file names this entry was computed from, sorted.
    public var revisionNames: [String] { (Array(revisions.keys) + Array(unreadable.keys)).sorted() }
}

/// The rule-4 bookkeeping shared by the index and `Vault.collectBlobs`.
public enum BlobRetention {
    /// `records` after a look that found `unreferenced` (file names)
    /// unreferenced with rules 1–3 holding: a file seen before keeps its
    /// time, a new one gets `now`, and a file no longer unreferenced (used
    /// again, or gone) loses its record, so its window restarts if it is
    /// ever unused again.
    public static func observe(unreferenced: some Sequence<String>, records: [String: Date], now: Date) -> [String: Date] {
        var out: [String: Date] = [:]
        for name in unreferenced { out[name] = records[name] ?? now }
        return out
    }

    /// When a blob first seen unreferenced at `firstSeen` may be deleted.
    public static func deletableFrom(_ firstSeen: Date, retention: TimeInterval = CompactionPlanner.defaultRetention) -> Date {
        firstSeen.addingTimeInterval(retention)
    }
}

/// Updates attachment index entries, one note at a time.
public enum AttachmentIndexer {
    /// The longest `title` kept from a reference's holder.
    static let maxTitle = 200

    /// The entry of `note` after a change, from `previous` (nil: none yet).
    ///
    /// Work, all on this one note: one listing of `att/`; when it holds blob
    /// files, one listing of the note's revisions and one decryption of each
    /// revision `previous` has not read (none for an unchanged note). No
    /// other note is touched.
    ///
    /// - Parameters:
    ///   - current: the hashes the note's current state references (a
    ///     summary's `blobs`, an open editor's items); nil keeps `previous`'s.
    ///   - local: false when (iCloud Drive) not every revision of the note is
    ///     on this device: nothing is decided, as for an unreadable revision.
    public static func update(note: UUID, previous: AttachmentIndexEntry?, source: some AttachmentIndexSource,
                              current: Set<String>?, local: Bool = true, now: Date = Date()) -> AttachmentIndexEntry {
        let previous = previous?.schema == AttachmentIndexEntry.schemaVersion && previous?.note == note ? previous : nil
        var e = AttachmentIndexEntry(note: note)
        e.checked = now
        e.current = current.map { $0.sorted() } ?? previous?.current
        e.revisions = previous?.revisions ?? [:]
        let lastUses = Dictionary((previous?.files ?? []).compactMap { f in f.lastUse.map { (f.fileName, $0) } },
                                  uniquingKeysWith: { a, _ in a })
        let listed: [AttachmentIndexEntry.Listed]
        do { listed = try source.blobFiles(note: note) } catch {
            e.problem = "cannot list the note's attachments: \(error)"
            e.files = previous?.files ?? []
            return e   // rule 1 fails: no records
        }
        // No blob files: nothing to report, nothing to decrypt.
        guard !listed.isEmpty else { return e }
        guard local else {
            e.problem = "not every revision of the note is on this device"
            e.files = previous?.files ?? []
            return e
        }
        let names: [RevisionName]
        do { names = try source.revisionNames(of: note) } catch {
            e.problem = "cannot list the note: \(error)"
            e.files = previous?.files ?? []
            return e
        }
        var revisions: [String: AttachmentIndexEntry.RevisionFacts] = [:]
        for n in names {
            if let known = e.revisions[n.filename] { revisions[n.filename] = known; continue }
            do { revisions[n.filename] = try source.blobFacts(note: note, revision: n) } catch {
                e.unreadable[n.filename] = "\(error)"
            }
        }
        e.revisions = revisions
        if source.pendingRewrap { e.problem = "a recipient change is unfinished" }

        // Name stem → hash, and per hash the revisions that reference it (oldest first).
        var byName: [String: String] = [:]
        var users: [String: [RevisionName]] = [:]
        for n in names {
            guard let facts = revisions[n.filename] else { continue }
            for sha in Set(facts.refs.map(\.sha256)) { users[sha, default: []].append(n) }
        }
        for sha in users.keys { for stem in source.blobNames(sha256: sha) { byName[stem] = sha } }
        e.files = listed.map { l in
            let sha = byName[l.name]
            var lastUse = lastUses[l.fileName]
            if let sha, let newest = users[sha]?.last, let facts = revisions[newest.filename],
               let ref = facts.refs.last(where: { $0.sha256 == sha }) {
                lastUse = .init(revision: newest.filename, wall: facts.wall, type: ref.type, size: ref.size,
                                duration: ref.duration, title: ref.title)
            }
            return .init(fileName: l.fileName, kind: l.kind, bytes: l.bytes, sha256: sha,
                         revisions: sha.flatMap { users[$0]?.map(\.filename) } ?? [], lastUse: lastUse)
        }
        if e.isComplete {
            e.unusedSince = BlobRetention.observe(unreferenced: e.files.filter { $0.sha256 == nil }.map(\.fileName),
                                                  records: previous?.unusedSince ?? [:], now: now)
        }
        return e
    }
}

// MARK: - Report

/// The numbers and lists of Settings → Storage and `sempere blobs unused`,
/// from index entries (docs/attachments.md §4).
public struct AttachmentStorageReport: Hashable, Sendable {
    /// A blob no revision of its note references.
    public struct Unused: Hashable, Sendable, Identifiable {
        public var note: UUID
        public var fileName: String
        public var kind: BlobKind
        public var bytes: Int64
        /// When this device first found it unreferenced.
        public var firstSeen: Date
        /// `firstSeen` + the retention window.
        public var deletableFrom: Date
        /// The newest revision that used it, if this device saw one.
        public var lastUse: AttachmentIndexEntry.LastUse?

        public init(note: UUID, fileName: String, kind: BlobKind, bytes: Int64, firstSeen: Date, deletableFrom: Date,
                    lastUse: AttachmentIndexEntry.LastUse?) {
            self.note = note; self.fileName = fileName; self.kind = kind; self.bytes = bytes
            self.firstSeen = firstSeen; self.deletableFrom = deletableFrom; self.lastUse = lastUse
        }

        public var id: String { "\(note.uuidString.lowercased())/\(fileName)" }

        /// True from `deletableFrom` on (exactly the retention window after `firstSeen`).
        public func isEligible(at now: Date) -> Bool { now >= deletableFrom }
    }

    /// A blob some surviving revision references but the current note does not show.
    public struct Held: Hashable, Sendable, Identifiable {
        public var note: UUID
        public var fileName: String
        public var kind: BlobKind
        public var bytes: Int64
        public var sha256: String
        /// The revisions that reference it, oldest first.
        public var revisions: [String]
        public var lastUse: AttachmentIndexEntry.LastUse?

        public init(note: UUID, fileName: String, kind: BlobKind, bytes: Int64, sha256: String, revisions: [String],
                    lastUse: AttachmentIndexEntry.LastUse?) {
            self.note = note; self.fileName = fileName; self.kind = kind; self.bytes = bytes; self.sha256 = sha256
            self.revisions = revisions; self.lastUse = lastUse
        }

        public var id: String { "\(note.uuidString.lowercased())/\(fileName)" }
    }

    /// Biggest first, then by note and name.
    public var unused: [Unused] = []
    /// Biggest first, then by note and name.
    public var held: [Held] = []
    /// Notes nothing could be decided about, with the reason.
    public var unchecked: [UUID: String] = [:]
    public var retention: TimeInterval

    public init(entries: some Sequence<AttachmentIndexEntry>, retention: TimeInterval = CompactionPlanner.defaultRetention) {
        self.retention = retention
        for e in entries {
            if !e.isComplete {
                if !e.files.isEmpty {
                    unchecked[e.note] = e.problem ?? "\(e.unreadable.count) unreadable revision(s)"
                }
                continue
            }
            for f in e.unused {
                // A complete entry records every unreferenced file; a missing record is
                // an entry from before the look (never deletable before it is seen).
                guard let first = e.unusedSince[f.fileName] else { continue }
                unused.append(.init(note: e.note, fileName: f.fileName, kind: f.kind, bytes: f.bytes, firstSeen: first,
                                    deletableFrom: BlobRetention.deletableFrom(first, retention: retention),
                                    lastUse: f.lastUse))
            }
            for f in e.heldByHistory {
                guard let sha = f.sha256 else { continue }
                held.append(.init(note: e.note, fileName: f.fileName, kind: f.kind, bytes: f.bytes, sha256: sha,
                                  revisions: f.revisions, lastUse: f.lastUse))
            }
        }
        unused.sort { ($1.bytes, $0.id) < ($0.bytes, $1.id) }
        held.sort { ($1.bytes, $0.id) < ($0.bytes, $1.id) }
    }

    public var unusedBytes: Int64 { unused.reduce(0) { $0 + $1.bytes } }
    public var heldBytes: Int64 { held.reduce(0) { $0 + $1.bytes } }
    /// The unused blobs that may be deleted at `now`.
    public func eligible(at now: Date) -> [Unused] { unused.filter { $0.isEligible(at: now) } }
    /// Their bytes.
    public func eligibleBytes(at now: Date) -> Int64 { eligible(at: now).reduce(0) { $0 + $1.bytes } }
}

// MARK: - Vault as a source

extension Vault: AttachmentIndexSource {
    public func blobFacts(note: UUID, revision: RevisionName) throws -> AttachmentIndexEntry.RevisionFacts {
        try requireMigrated()
        let secret = try requireReadable()
        let data: Data
        do {
            data = try FileIO.read(noteURL(note).appendingPathComponent(revision.filename), maxBytes: BoundedRead.maxRevisionBytes)
        } catch {
            throw RevisionReadError.unreadable("\(error)")
        }
        let json = try revisionJSON(data, note: note.uuidString.lowercased(), name: revision, secret: secret)
        do { return try BlobReferenceScan.facts(in: json) } catch { throw RevisionReadError.undecodable("\(error)") }
    }

    public func blobFiles(note: UUID) throws -> [AttachmentIndexEntry.Listed] {
        let att = attURL(note)
        var out: [AttachmentIndexEntry.Listed] = []
        for e in try FileIO.entries(att) {
            let url = att.appendingPathComponent(e)
            guard let parsed = BlobName.parse(e), !FileIO.isDirectory(url) else { continue }
            let bytes = FileIO.size(url) ?? 0
            out.append(.init(fileName: e, kind: parsed.kind, bytes: bytes, name: parsed.name))
        }
        return out
    }

    public func blobNames(sha256: String) -> [String] {
        guard let digest = Hex.decode(sha256) else { return [] }
        return blobSecrets.map { BlobName.name(digest: digest, secret: $0) }
    }

    /// The verified content of one blob file of `note` whether or not a
    /// revision references it (Settings shows unused images and PDFs):
    /// framing, padding, content hash and the keyed name are all checked
    /// before anything is returned. In memory only; nothing is written.
    ///
    /// - Throws: `BlobError` (`contentTooLarge` beyond `maxBytes`,
    ///   `missing` when there is no such file), `VaultError.locked`.
    public func readBlobFile(note: UUID, fileName: String, maxBytes: Int = Vault.maxInMemoryBlobBytes) throws
        -> (sha256: String, content: Data) {
        try requireMigrated()
        _ = try requireSecret()
        guard BlobName.parse(fileName) != nil else { throw BlobError.invalidReference }
        let url = attURL(note).appendingPathComponent(fileName)
        guard FileIO.exists(url) else { throw BlobError.missing(url.path) }
        var out = Data()
        let (header, _) = try Self.readBlobFile(url, identities: identities, secrets: blobSecrets, expected: nil,
                                                maxContent: Int64(maxBytes), sink: { out.append($0) })
        return (header.sha256, out)
    }

    /// The index entry of `note` computed afresh with this device's rule-4
    /// `records` (every revision read; for the CLI, which keeps no index).
    public func attachmentIndexEntry(note: UUID, records: [String: Date], current: Set<String>?,
                                     now: Date = Date()) -> AttachmentIndexEntry {
        var seed = AttachmentIndexEntry(note: note)
        seed.unusedSince = records
        return AttachmentIndexer.update(note: note, previous: seed, source: self, current: current, now: now)
    }
}
