import Foundation

// MARK: - Make a Copy (docs/design/1.2-make-a-copy.md)

/// A request to stop a copy, set by the host (the app's Cancel) and checked between notes. A cancelled copy
/// throws `CopyError.cancelled`; the vault being built in the store's staging folder is discarded with it.
public final class CopyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// How far a copy has come, told after every note (any thread; a host hops to its own).
public struct CopyProgress: Sendable, Equatable {
    /// Notes dealt with (copied, skipped or failed).
    public var done: Int
    /// Notes in the source.
    public var total: Int
    /// Notes written so far.
    public var notes: Int
    /// Attachment bytes written (or, in a dry run, read) so far.
    public var blobBytes: Int64

    public init(done: Int, total: Int, notes: Int, blobBytes: Int64) {
        self.done = done; self.total = total; self.notes = notes; self.blobBytes = blobBytes
    }

    /// 0 ... 1.
    public var fraction: Double { total > 0 ? Double(min(max(done, 0), total)) / Double(total) : 0 }
}

/// Why a copy stopped without a result.
public enum CopyError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The host asked to stop (`CopyCancellation`).
    case cancelled
    /// The source is only partly downloaded (format.md §1.2): download it first.
    case partialSource
    /// The source cannot be read: it is locked.
    case unreadableSource
    /// `Options.strict`: the first note that could not be copied.
    case stopped(note: UUID, reason: String)

    public var description: String {
        switch self {
        case .cancelled: return "the copy was canceled"
        case .partialSource: return "the vault is only partly downloaded; download every note first"
        case .unreadableSource: return "the vault cannot be read: it is locked"
        case .stopped(let note, let reason): return "note \(note.uuidString.lowercased()) could not be copied: \(reason)"
        }
    }
}

/// What a copy did: the facts for the CLI's `--json` and for the app's result.
public struct CopyReport: Codable, Equatable, Sendable {
    /// A note left out, and why.
    public struct Skipped: Codable, Equatable, Sendable {
        public var note: String
        public var reason: String

        public init(note: String, reason: String) { self.note = note; self.reason = reason }
    }

    /// What a newer version wrote in a source note that this version could not read (format.md §7.4): lost in the copy.
    public struct NewerNote: Codable, Equatable, Sendable {
        public var note: String
        /// Skipped ops by name (`NewerContent.skippedOps`).
        public var skippedOps: [String: Int]
        /// Snapshot elements skipped because they did not decode.
        public var skippedElements: Int
        /// Revisions that could not be read at all.
        public var unreadableRevisions: Int
        /// Revisions read leniently.
        public var newerRevisions: Int

        public init(note: String, skippedOps: [String: Int], skippedElements: Int, unreadableRevisions: Int,
                    newerRevisions: Int) {
            self.note = note; self.skippedOps = skippedOps; self.skippedElements = skippedElements
            self.unreadableRevisions = unreadableRevisions; self.newerRevisions = newerRevisions
        }
    }

    /// Nothing was written (a dry run): the numbers are what a copy would write.
    public var dryRun = false
    public var sourceVaultId: String
    /// The new vault's id; nil in a dry run.
    public var destinationVaultId: String?
    /// Notes in the source.
    public var sourceNotes = 0
    /// Notes written (the deleted ones included).
    public var notes = 0
    public var pages = 0
    public var strokes = 0
    public var items = 0
    public var recordings = 0
    public var blobs = 0
    public var blobBytes: Int64 = 0
    /// Deleted notes written (`Options.includeDeleted`).
    public var deletedCopied = 0
    /// Deleted notes left out on purpose.
    public var deletedSkipped = 0
    /// Notebooks the source declared (and a copied note is in) that were declared in the copy.
    public var notebooks = 0
    /// Notes that could not be read or written: the copy lacks them.
    public var failed: [Skipped] = []
    /// Notes whose source held content of a newer version.
    public var newer: [NewerNote] = []
    /// What to tell about the source before trusting the copy (English).
    public var warnings: [String] = []

    public init(sourceVaultId: String) { self.sourceVaultId = sourceVaultId }

    /// Every note that was meant to be copied was written (a deleted note left out on purpose does not count).
    public var isComplete: Bool { failed.isEmpty }

    /// Some content of a newer version is not in the copy.
    public var isMissingNewerContent: Bool { !newer.isEmpty }
}

/// Make a Copy… of a vault: a new vault of the user's own, with the same notes in their current state
/// (docs/design/1.2-make-a-copy.md). The source is only read (readable with a device key, the recovery key, a
/// newer format, an untrusted list or after this device was removed); the destination is a vault made by
/// `VaultCreation` with its own keys, built inside a store's staging folder (`VaultStore.create`) so it
/// appears complete or not at all.
///
/// Per note, in memory one at a time: reduce the source to its current state, copy every blob it references
/// (streamed, verified as read, written before the delta that names it, format.md §8.1.4), then write one
/// checkpoint delta (§5.8.1) as the destination's device. Note, page, stroke, item and recording ids are kept.
/// History, devices, sync targets, settings and the inbox are not copied.
public enum VaultCopier {
    public struct Options: Sendable {
        /// Copy the notes in Recently Deleted too, in their deleted state.
        public var includeDeleted = false
        /// Stop at the first note that cannot be copied (`CopyError.stopped`) instead of listing it in the report.
        public var strict = false
        /// The `app` of the written revisions.
        public var app = "sempere"
        /// How the source is named in each note's checkpoint ("Copied from <name>"); nil: the vault's label.
        public var sourceName: String?
        /// This device's write ledger of the destination (design §5.4), so a later epoch change can catch the
        /// copied files up; nil keeps none (tests).
        public var ledger: (any WriteLedgerStore)?
        /// The time of the clock readings and notebook records.
        public var now: @Sendable () -> Date = { Date() }

        public init(includeDeleted: Bool = false, strict: Bool = false, app: String = "sempere", sourceName: String? = nil,
                    ledger: (any WriteLedgerStore)? = nil) {
            self.includeDeleted = includeDeleted; self.strict = strict; self.app = app; self.sourceName = sourceName
            self.ledger = ledger
        }
    }

    /// The checkpoint's name: "Copied from <source>".
    public static func checkpointName(source: String?) -> String {
        "Copied from " + (source.flatMap { $0.isEmpty ? nil : $0 } ?? "another vault")
    }

    /// What is worth telling about `source` before a copy of it is trusted.
    public static func sourceWarnings(of source: Vault) -> [String] {
        var out: [String] = []
        if let problem = source.listStatus.problem {
            out.append("this device could not confirm the vault's device list (\(problem)); the copy starts its own trust")
        }
        if source.unlistedNotice != nil {
            out.append("this device was removed from the vault: notes written under later keys cannot be read and are missing")
        }
        let reasons = source.readOnlyReasons
        if reasons.vaultFormat != nil || !reasons.unknownFeatures.isEmpty {
            out.append("the vault is of a newer format: what this version does not understand is not in the copy")
        }
        return out
    }

    /// Copies the notes of `source` into `destination`, or, with `destination` nil, reads them all and reports
    /// what a copy would write (a dry run: nothing is written, blobs are read and verified).
    ///
    /// The destination must be a writable vault of its own (`VaultCreation`), opened as `device` with `clock`.
    /// A failure inside `VaultStore.create`'s `build` leaves nothing in the store.
    ///
    /// - Throws: `CopyError` (`cancelled`, `partialSource`, `stopped`), `VaultError` when the destination cannot be
    ///   written. A note that cannot be read or copied is in `CopyReport.failed` unless `options.strict`.
    public static func copy(from source: Vault, into destination: Vault?, device: DeviceID, clock: inout HybridClock,
                            options: Options = Options(), progress: (@Sendable (CopyProgress) -> Void)? = nil,
                            cancellation: CopyCancellation? = nil) throws -> CopyReport {
        guard source.canRead else { throw CopyError.unreadableSource }
        if source.isPartialCopy { throw CopyError.partialSource }
        var dest = destination
        if let ledger = options.ledger { dest?.ledger = ledger }
        var report = CopyReport(sourceVaultId: source.vaultId.uuidString.lowercased())
        report.dryRun = dest == nil
        report.destinationVaultId = dest?.vaultId.uuidString.lowercased()
        report.warnings = sourceWarnings(of: source)
        let ids = try source.noteIDs()
        report.sourceNotes = ids.count
        let checkpoint = Checkpoint(name: checkpointName(source: options.sourceName ?? source.label))
        var usedNotebooks: [String] = []
        for (i, id) in ids.enumerated() {
            if cancellation?.isCancelled == true { throw CopyError.cancelled }
            do {
                if let notebook = try copyNote(id, from: source, into: dest, device: device, clock: &clock, options: options,
                                               checkpoint: checkpoint, cancellation: cancellation, report: &report) {
                    usedNotebooks.append(notebook)
                }
            } catch let e as CopyError {
                throw e
            } catch {
                let reason = describe(error)
                if options.strict { throw CopyError.stopped(note: id, reason: reason) }
                report.failed.append(.init(note: id.uuidString.lowercased(), reason: reason))
            }
            progress?(CopyProgress(done: i + 1, total: ids.count, notes: report.notes, blobBytes: report.blobBytes))
        }
        if cancellation?.isCancelled == true { throw CopyError.cancelled }
        report.notebooks = try copyNotebooks(from: source, into: dest, used: usedNotebooks, now: options.now(),
                                             warnings: &report.warnings)
        return report
    }

    /// Copies one note; returns its notebook ("" for none) when it was written.
    private static func copyNote(_ id: UUID, from source: Vault, into dest: Vault?, device: DeviceID,
                                 clock: inout HybridClock, options: Options, checkpoint: Checkpoint,
                                 cancellation: CopyCancellation?, report: inout CopyReport) throws -> String? {
        let loaded = try source.loadNote(id)
        // Strict: any revision that failed to read fails the note (newer ones are reported, not failed).
        let state = try source.reconstruct(loaded)
        if let newer = loaded.newer {
            report.newer.append(.init(note: id.uuidString.lowercased(), skippedOps: newer.skippedOps,
                                      skippedElements: newer.skippedElements, unreadableRevisions: newer.unreadable,
                                      newerRevisions: newer.revisions))
        }
        if state.deleted, !options.includeDeleted {
            report.deletedSkipped += 1
            return nil
        }
        let ops = Self.ops(for: state)
        let refs = try Self.blobReferences(of: state, ops: ops)
        var bytes: Int64 = 0
        var wroteAnything = false
        do {
            // Blobs first: a delta never names a blob that is not written yet (format.md §8.1.4).
            for ref in refs {
                try copyBlob(ref, note: id, from: source, into: dest, cancellation: cancellation)
                wroteAnything = true
                bytes += ref.size
            }
            if let dest {
                let now = options.now()
                let wall = min(ModifiedDate.of(loaded.revisions) ?? state.meta.created, now)
                let hlc = clock.tick(wall: now)
                wroteAnything = true
                try dest.write(Revision(noteId: id, device: device, seq: 1, hlc: hlc, wall: wall, app: options.app,
                                        body: .delta(ops: ops), checkpoint: checkpoint))
            }
        } catch {
            // Nothing of a failed note stays in the new vault (its blobs would be unreferenced).
            if let dest, wroteAnything { try? FileManager.default.removeItem(at: dest.noteURL(id)) }
            throw error
        }
        report.notes += 1
        report.pages += state.pages.count
        report.strokes += state.pages.reduce(0) { $0 + $1.strokes.count }
        report.items += state.pages.reduce(0) { $0 + $1.items.count }
        report.recordings += state.recordings.count
        report.blobs += refs.count
        report.blobBytes += bytes
        if state.deleted { report.deletedCopied += 1 }
        return state.meta.notebook ?? ""
    }

    /// Reads the blob `ref` of `note` through the source (framing, hash and keyed name checked) and writes it to the
    /// destination's copy of the note; with no destination it is only read.
    /// A cancel is checked in every piece, so a clip of a gigabyte stops at once.
    private static func copyBlob(_ ref: BlobRef, note: UUID, from source: Vault, into dest: Vault?,
                                 cancellation: CopyCancellation?) throws {
        guard let dest else {
            try source.streamBlob(note: note, ref, maxBytes: ref.size) { _ in
                if cancellation?.isCancelled == true { throw CopyError.cancelled }
            }
            return
        }
        guard let digest = ref.digest else { throw BlobError.invalidReference }
        try dest.writeBlobStream(note: note, ref: ref, digest: digest) { emit in
            try source.streamBlob(note: note, ref, maxBytes: ref.size) {
                if cancellation?.isCancelled == true { throw CopyError.cancelled }
                try emit($0)
            }
        }
    }

    /// Every blob the note's written ops reference: the state's known references, then any other object with a
    /// `sha256` in the encoded ops (format.md §8.1.1: found structurally, so a field a later version added to an item,
    /// a recording or a text run is copied with its blob, never left dangling). A well-formed reference found there
    /// is read like the others, so one that cannot be read fails the note.
    static func blobReferences(of state: NoteState, ops: [Op]) throws -> [BlobRef] {
        var refs = state.blobReferences
        var seen = Set(refs.map(\.sha256))
        let encoded = try JSONEncoder().encode(ops)
        for found in try BlobReferenceScan.references(in: encoded) {
            guard let ref = found.ref, seen.insert(ref.sha256).inserted else { continue }
            refs.append(ref)
        }
        return refs
    }

    /// The notebooks the source declared (format.md §14) that a copied note is in or below, declared in the copy.
    private static func copyNotebooks(from source: Vault, into dest: Vault?, used: [String], now: Date,
                                      warnings: inout [String]) throws -> Int {
        guard !used.isEmpty else { return 0 }
        let declared: [String]
        do {
            let records = try source.readNotebookRecords()
            if !records.problems.isEmpty {
                warnings.append("\(records.problems.count) notebook records could not be read: empty notebooks they declare may be missing")
            }
            declared = records.declared
        } catch {
            warnings.append("the notebook records could not be read (\(describe(error))): empty notebooks may be missing")
            declared = []
        }
        var count = 0
        for path in declared where used.contains(where: { !$0.isEmpty && NotebookPath.name($0, isWithin: path) }) {
            guard let dest else { count += 1; continue }
            if try dest.createNotebook(path, now: now) != nil { count += 1 }
        }
        return count
    }

    /// The ops that write `state` into a note that has none (what an importer writes): every page, stroke and item,
    /// the meta registers, the recordings, the tags, each page's recognition and paper, and `deleteNote` for a deleted
    /// note. The snapshot-only fields (`origin`, `clocks`, `replaces`) are left out: the copy has its own history.
    static func ops(for state: NoteState) -> [Op] {
        var ops: [Op] = []
        for page in state.pages {
            ops.append(.addPage(Page(id: page.id, order: page.order, parent: page.parent)))
            for var s in page.strokes {
                s.origin = nil; s.replaces = false
                ops.append(.addStroke(page: page.id, stroke: s))
            }
            for var item in page.items {
                item.origin = nil; item.clocks = nil
                ops.append(.addItem(page: page.id, item: item))
            }
        }
        let m = state.meta
        ops.append(.setMeta(.title(m.title)))
        ops.append(.setMeta(.notebook(m.notebook)))
        ops.append(.setMeta(.paper(m.paper)))
        ops.append(.setMeta(.pageSize(m.pageSize)))
        if m.favorite { ops.append(.setMeta(.favorite(true))) }
        if let lang = m.lang { ops.append(.setMeta(.lang(lang))) }
        if m.markersBehindText { ops.append(.setMeta(.markersBehindText(true))) }
        if let recognized = m.recognized { ops.append(.setMeta(.recognized(recognized))) }
        for var r in state.recordings {
            r.origin = nil; r.clocks = nil
            ops.append(.addRecording(r))
        }
        // The tag rule's own builder, on a note with none (`NoteOps.tagKey` decides which spellings are one tag).
        ops += NoteOps.setTags(m.tags, on: NoteState(meta: NoteMeta(created: m.created)))
        for page in state.pages {
            if let paper = page.paper { ops.append(.setPagePaper(pageId: page.id, paper: paper)) }
            if let recognition = page.recognition { ops.append(.setPageRecognition(pageId: page.id, recognition: recognition)) }
        }
        if state.deleted { ops.append(.deleteNote) }
        return ops
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
