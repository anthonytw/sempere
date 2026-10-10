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

// `sempere blobs …`: the attachment blobs of each note (format.md §8.1,
// docs/attachments.md §4). Everything the app does with blobs is scriptable
// here: add, copy, extract, verify, list, collect, repair.

struct BlobsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blobs",
        abstract: "Attachment blobs (notes/<id>/att/): list, verify, extract, add, copy, collect, repair.",
        discussion: """
            Blobs hold the bytes of images, PDFs, recordings and transcripts, one encrypted file per content \
            per note, named by a keyed hash of the content (format.md §8.1). Revisions reference them by \
            SHA-256; nothing reads one note's blobs from another.
            """,
        subcommands: [BlobsList.self, BlobsVerify.self, BlobsExtract.self, BlobsAdd.self, BlobsCopy.self,
                      BlobsUnused.self, BlobsGC.self, BlobsRepair.self]
    )
}

/// Notes named on the command line (ids or titles), or every note.
private func notes(_ queries: [String], in vault: Vault) throws -> [UUID] {
    queries.isEmpty ? try vault.noteIDs() : try queries.map { try vault.resolveNote($0) }
}

private func noteName(_ id: UUID) -> String { id.uuidString.lowercased() }

// MARK: - list

struct BlobsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List each note's blobs: kind, size, referenced or not; and references with no blob.",
        discussion: "Reads the notes' revisions but decrypts no blob; `blobs verify` checks the blobs themselves."
    )

    @Argument(help: ArgumentHelp("Notes (id or title). Default: every note.", valueName: "note"))
    var note: [String] = []

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable {
        struct File: Encodable { var file: String; var kind: String; var bytes: Int64; var sha256: String?; var referenced: Bool }
        struct Missing: Encodable { var sha256: String; var type: String; var size: Int64; var file: String }
        var note: String
        var files: [File]
        var missing: [Missing]
        var unknown: [String]
        var unreadableRevisions: [String: String]
        var listingProblem: String?
    }

    func run() throws {
        let vault = try access.openVault(.required)
        var out: [Out] = []
        for id in try notes(note, in: vault) {
            let inv = try vault.blobInventory(note: id)
            if note.isEmpty && inv.files.isEmpty && inv.references.values.allSatisfy(\.isEmpty)
                && inv.unknownEntries.isEmpty && inv.isComplete { continue }
            out.append(Out(
                note: noteName(id),
                files: inv.files.map { .init(file: $0.fileName, kind: $0.kind.rawValue, bytes: $0.bytes, sha256: $0.sha256,
                                             referenced: $0.sha256 != nil) },
                missing: try inv.missing.map { .init(sha256: $0.sha256, type: $0.type, size: $0.size,
                                                      file: try vault.blobFileName(for: $0)) },
                unknown: inv.unknownEntries,
                unreadableRevisions: Dictionary(uniqueKeysWithValues: inv.unreadable.map { ($0.key.filename, "\($0.value)") }),
                listingProblem: inv.listingProblem))
        }
        if output.json { try output.emitJSON(out); return }
        var rows: [[String]] = []
        for n in out {
            for f in n.files {
                rows.append([n.note, f.referenced ? "referenced" : "unreferenced", f.kind, "\(f.bytes)", f.file])
            }
            for m in n.missing { rows.append([n.note, "MISSING", m.type, "\(m.size)", m.file]) }
            for u in n.unknown { rows.append([n.note, "unknown", "-", "-", u]) }
            for (r, why) in n.unreadableRevisions.sorted(by: { $0.key < $1.key }) {
                rows.append([n.note, "UNREADABLE", "-", "-", "\(r): \(why)"])
            }
            if let p = n.listingProblem { rows.append([n.note, "UNLISTABLE", "-", "-", p]) }
        }
        if !rows.isEmpty { print(Format.table(rows)) }
        let files = out.reduce(0) { $0 + $1.files.count }
        let bytes = out.reduce(Int64(0)) { $0 + $1.files.reduce(0) { $0 + $1.bytes } }
        output.info("\(files) blob(s), \(bytes) bytes on disk, in \(out.count) note(s)")
    }
}

// MARK: - verify

struct BlobsVerify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Decrypt and check every blob of the notes: framing, hash, name, recipients; find missing ones.",
        discussion: "Exit 0 only if every blob checked is healthy (ok or unreferenced), 3 otherwise."
    )

    @Argument(help: ArgumentHelp("Notes (id or title). Default: every note.", valueName: "note"))
    var note: [String] = []

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let ids = note.isEmpty ? nil : Set(try notes(note, in: vault))
        let report = vault.verify(notes: ids)
        let blobs = report.files.filter { $0.path.contains("/att") }
        let healthy: Set<VerifyReport.Status> = [.ok, .unreferenced, .unknownFile]
        let bad = blobs.filter { !healthy.contains($0.status) }
        if output.json {
            struct File: Encodable { var path: String; var status: String; var detail: String? }
            struct Out: Encodable { var healthy: Bool; var files: [File] }
            try output.emitJSON(Out(healthy: bad.isEmpty,
                                    files: blobs.map { File(path: $0.path, status: $0.status.rawValue, detail: $0.detail) }))
        } else {
            let shown = output.quiet ? bad : blobs
            let rows = shown.map { [$0.status.rawValue, $0.path + ($0.detail.map { "  (\($0))" } ?? "")] }
            if !rows.isEmpty { print(Format.table(rows)) }
            print("\(blobs.count) blob entr\(blobs.count == 1 ? "y" : "ies")" + (bad.isEmpty ? ": healthy" : ": \(bad.count) UNHEALTHY"))
        }
        if !bad.isEmpty { throw ExitCode(ExitStatus.unhealthy) }
    }
}

// MARK: - extract

struct BlobsExtract: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Write the verified content of a note's blob to a file or standard output.",
        discussion: """
            SHA256 is the content hash a revision of the note references (or a unique prefix of at least 8 \
            digits). With --out the file appears only once the whole content has verified, and an existing \
            file is never overwritten. On standard output content streams as it is decrypted: if the command \
            fails, discard what was printed.
            """
    )

    @Argument(help: ArgumentHelp("The note (id or title).", valueName: "note"))
    var note: String

    @Argument(help: ArgumentHelp("The content's SHA-256 (or a unique prefix).", valueName: "sha256"))
    var sha256: String

    @Option(name: .long, help: ArgumentHelp("Write to this new file instead of standard output.", valueName: "file"))
    var out: String?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard sha256.count >= 8, sha256.count <= 64,
              sha256.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { throw ValidationError("give the content's SHA-256: 8 to 64 lowercase hex digits") }
        if output.json && out == nil { throw ValidationError("--json needs --out (the content goes to standard output)") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let ref = try findReference(sha256, note: id, in: vault)
        if let out {
            let url = URL(fileURLWithPath: out)
            try writeNewFileAtomically(url) { write in try vault.streamBlob(note: id, ref) { try write($0) } }
            if output.json {
                struct Out: Encodable { var note: String; var sha256: String; var type: String; var size: Int64; var file: String }
                try output.emitJSON(Out(note: noteName(id), sha256: ref.sha256, type: ref.type, size: ref.size, file: out))
            } else {
                output.info("Wrote \(ref.size) bytes (\(ref.type)) to \(out)")
            }
        } else {
            do {
                try vault.streamBlob(note: id, ref) { piece in autoreleasing { FileHandle.standardOutput.write(piece) } }
            } catch {
                throw CLIError.failure("\(CLIError.from(error).message); discard the output printed so far")
            }
        }
    }
}

/// The reference with this hash (or unique prefix) in a note's revisions.
func findReference(_ query: String, note: UUID, in vault: Vault) throws -> BlobRef {
    let inv = try vault.blobInventory(note: note)
    var matches: [String: BlobRef] = [:]
    for r in inv.references.values.joined() where r.sha256.hasPrefix(query) {
        if let ref = r.ref, matches[ref.sha256] == nil { matches[ref.sha256] = ref }
    }
    guard let first = matches.first else {
        let unread = inv.unreadable.isEmpty ? "" : " (\(inv.unreadable.count) revision(s) could not be read)"
        throw CLIError.failure("no revision of note \(noteName(note)) references a blob \(query)\(unread)")
    }
    guard matches.count == 1 else {
        throw CLIError.failure("'\(query)' matches several blobs: \(matches.keys.sorted().joined(separator: ", "))")
    }
    return first.value
}

/// Creates `url` with the bytes `body` writes: a private temporary file next
/// to it, put in place with `link(2)` only once `body` succeeded (never over
/// an existing file).
func writeNewFileAtomically(_ url: URL, _ body: (_ write: (Data) throws -> Void) throws -> Void) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { throw CLIError.failure("refusing to overwrite \(url.path)") }
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).sempere-tmp-\(UUID().uuidString.lowercased())")
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { throw CLIError.failure("cannot create \(tmp.path): \(String(cString: strerror(errno)))") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try body { piece in try autoreleasing { try handle.write(contentsOf: piece) } }
    try handle.synchronize()
    guard link(tmp.path, url.path) == 0 else {
        if errno == EEXIST { throw CLIError.failure("refusing to overwrite \(url.path)") }
        throw CLIError.failure("cannot create \(url.path): \(String(cString: strerror(errno)))")
    }
}

// MARK: - add, copy

struct BlobsAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Store a file as a blob of a note and print its reference (for scripts; adds no item).",
        discussion: """
            Prints the blob reference ({"sha256", "size", "type"}) to put in a revision. Until a revision \
            references it the blob is unreferenced, and `blobs gc` removes it after the retention window.
            """
    )

    @Argument(help: ArgumentHelp("The note (id or title).", valueName: "note"))
    var note: String

    @Argument(help: ArgumentHelp("The file to store.", valueName: "file"))
    var file: String

    @Option(name: .long, help: ArgumentHelp("Its media type, e.g. image/jpeg, application/pdf, audio/mp4.",
                                            valueName: "type"))
    var type: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let ref = try vault.writeBlob(note: id, contentsOf: URL(fileURLWithPath: file), type: type)
        struct Out: Encodable { var note: String; var sha256: String; var size: Int64; var type: String; var file: String }
        let o = Out(note: noteName(id), sha256: ref.sha256, size: ref.size, type: ref.type, file: try vault.blobFileName(for: ref))
        if output.json { try output.emitJSON(o); return }
        if output.quiet { print(ref.sha256); return }
        print("\(o.note)/att/\(o.file)")
        // Encoded, not interpolated: the media type is the caller's text.
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try enc.encode(ref), as: UTF8.self))
    }
}

struct BlobsCopy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy a blob one note references into another note (before writing a revision there that uses it).")

    @Argument(help: ArgumentHelp("The content's SHA-256 (or a unique prefix).", valueName: "sha256"))
    var sha256: String

    @Option(name: .long, help: ArgumentHelp("The note that has it (id or title).", valueName: "note"))
    var from: String

    @Option(name: .long, help: ArgumentHelp("The note to copy it into (id or title).", valueName: "note"))
    var to: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let src = try vault.resolveNote(from), dst = try vault.resolveNote(to)
        let ref = try findReference(sha256, note: src, in: vault)
        try vault.copyBlob(ref, from: src, to: dst)
        let file = try vault.blobFileName(for: ref)
        output.info("Copied \(ref.sha256) to \(noteName(dst))/att/\(file)")
    }
}

// MARK: - unused, gc

/// Shared by `unused` and `gc`.
struct CollectionOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("Retention window in days (format.md §8.1.6).", valueName: "days"))
    var retention: Double = CompactionPlanner.defaultRetention / 86400

    func validate() throws {
        guard retention >= 0, retention.isFinite else { throw ValidationError("--retention must not be negative") }
    }
}

private struct CollectionOut: Encodable {
    struct Unused: Encodable { var file: String; var kind: String; var bytes: Int64; var firstSeen: Date; var deletableFrom: Date }
    var note: String
    var blocked: String?
    var referenced: Int
    var unused: [Unused]
    var deleted: [String]
    var failures: [String: String]

    init(_ r: BlobCollectionReport) {
        note = noteName(r.note); blocked = r.blocked; referenced = r.referenced
        unused = r.unused.map { .init(file: $0.fileName, kind: $0.kind.rawValue, bytes: $0.bytes, firstSeen: $0.firstSeen,
                                      deletableFrom: $0.deletableFrom) }
        deleted = r.deleted; failures = r.failures
    }
}

/// What Settings → Storage shows (docs/attachments.md §4), computed with
/// this device's records: the same `AttachmentStorageReport` the app builds
/// from its index.
struct StorageOut: Encodable {
    struct Total: Encodable { var count: Int; var bytes: Int64 }
    struct LastUse: Encodable { var revision: String; var wall: Date?; var duration: Double?; var title: String? }
    struct Unused: Encodable {
        var note: String; var title: String; var file: String; var kind: String; var bytes: Int64
        var firstSeen: Date; var deletableFrom: Date; var eligible: Bool; var lastUse: LastUse?
    }
    struct Held: Encodable {
        var note: String; var title: String; var file: String; var kind: String; var bytes: Int64
        var sha256: String; var revisions: [String]
    }
    var retentionDays: Double
    var unused: Total
    var eligible: Total
    var heldByHistory: Total
    var items: [Unused]
    var held: [Held]
    /// Notes nothing could be decided about (unreadable revision, recipient change unfinished).
    var unchecked: [String: String]

    init(_ r: AttachmentStorageReport, titles: [UUID: String], now: Date) {
        retentionDays = r.retention / 86400
        unused = Total(count: r.unused.count, bytes: r.unusedBytes)
        let ok = r.eligible(at: now)
        eligible = Total(count: ok.count, bytes: r.eligibleBytes(at: now))
        heldByHistory = Total(count: r.held.count, bytes: r.heldBytes)
        items = r.unused.map { u in
            Unused(note: noteName(u.note), title: titles[u.note] ?? "", file: u.fileName, kind: u.kind.rawValue,
                   bytes: u.bytes, firstSeen: u.firstSeen, deletableFrom: u.deletableFrom, eligible: u.isEligible(at: now),
                   lastUse: u.lastUse.map { LastUse(revision: $0.revision, wall: $0.wall, duration: $0.duration, title: $0.title) })
        }
        held = r.held.map {
            Held(note: noteName($0.note), title: titles[$0.note] ?? "", file: $0.fileName, kind: $0.kind.rawValue,
                 bytes: $0.bytes, sha256: $0.sha256, revisions: $0.revisions)
        }
        unchecked = Dictionary(uniqueKeysWithValues: r.unchecked.map { (noteName($0.key), $0.value) })
    }

    /// "Unused attachments: N items, X MB (M eligible now); held by history: …" for people.
    var line: String {
        "Unused attachments: \(unused.count) item(s), \(Format.bytes(Int(unused.bytes)))"
            + " (\(eligible.count) deletable now, \(Format.bytes(Int(eligible.bytes))));"
            + " held by history: \(heldByHistory.count) item(s), \(Format.bytes(Int(heldByHistory.bytes)))"
    }
}

/// The storage report of `ids` with this device's collection `state`
/// (read, never updated): every revision of each note is read
/// (`Vault.attachmentIndexEntry`), and the current state's references come
/// from the notes' summaries (the summary cache when present).
func storageReport(_ vault: Vault, _ ids: [UUID], state: BlobCollectorState, retention: Double, now: Date,
                   cache: SummaryCache?) throws -> (AttachmentStorageReport, titles: [UUID: String]) {
    let summaries = try vault.summaries(of: ids, cache: cache)
    let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let state = state.vaultId == vault.vaultId ? state : BlobCollectorState(vaultId: vault.vaultId)
    var entries: [AttachmentIndexEntry] = []
    for id in ids {
        // A summary with a problem says nothing reliable about the current state.
        let current = byID[id].flatMap { $0.problem == nil ? Set($0.blobs.map(\.sha256)) : nil }
        entries.append(vault.attachmentIndexEntry(note: id, records: state.notes[noteName(id)] ?? [:], current: current,
                                                  now: now))
    }
    return (AttachmentStorageReport(entries: entries, retention: retention * 86400), byID.mapValues(\.title))
}

struct BlobsUnused: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unused",
        abstract: "Unused attachments: blobs no revision of their note references, when each may be deleted, and space held by history.",
        discussion: """
            The numbers Settings → Storage shows in the app: unused blobs (count, bytes, the date each was \
            first seen unused and may be deleted, and whether it may be deleted now), and blobs only older \
            revisions use ("held by history": freed when compaction drops those revisions). Read only: uses \
            this device's collection record ($XDG_STATE_HOME/sempere/blobs/<vaultId>.json) without updating \
            it, so a blob not seen before shows today's date; `blobs gc` records it. The app keeps its own \
            record. Exit 3 when a note could not be checked.
            """
    )

    @Argument(help: ArgumentHelp("Notes (id or title). Default: every note.", valueName: "note"))
    var note: [String] = []

    @OptionGroup var collection: CollectionOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let state = try BlobCollectorState.load(from: BlobCollectorState.defaultURL(vaultId: vault.vaultId),
                                                vaultId: vault.vaultId)
        let now = Date()
        let (report, titles) = try storageReport(vault, try notes(note, in: vault), state: state,
                                                 retention: collection.retention, now: now, cache: cache.cache(for: vault))
        let out = StorageOut(report, titles: titles, now: now)
        if output.json { try output.emitJSON(out) } else {
            var rows: [[String]] = []
            for (n, why) in out.unchecked.sorted(by: { $0.key < $1.key }) { rows.append([n, "NOT CHECKED", "-", "-", why]) }
            for u in out.items {
                rows.append([u.note, u.kind, Format.bytes(Int(u.bytes)),
                             u.eligible ? "deletable now" : "deletable from \(Format.local(u.deletableFrom))", u.file])
            }
            for h in out.held { rows.append([h.note, "\(h.kind) (history)", Format.bytes(Int(h.bytes)), "in \(h.revisions.count) revision(s)", h.file]) }
            if !rows.isEmpty { print(Format.table(rows)) }
            output.info(out.line)
        }
        if !report.unchecked.isEmpty { throw ExitCode(ExitStatus.unhealthy) }
    }
}

struct BlobsGC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Delete blobs no revision of their note has referenced for the retention window (format.md §8.1.6).",
        discussion: """
            Per note: only when every revision of the note was read and verified, no recipient change is \
            pending, no revision references the blob, and this device first found it so at least --retention \
            days ago (recorded in $XDG_STATE_HOME/sempere/blobs/<vaultId>.json, never in the vault). Blobs \
            that cannot be verified are reported, never deleted. With --dry-run nothing is deleted or recorded. \
            With --file only those blob files may be deleted (the app's per-item Delete). Afterwards prints \
            what `blobs unused` prints. Exit 3 when a note could not be collected or a blob could not be verified.
            """
    )

    @Argument(help: ArgumentHelp("Notes (id or title). Default: every note.", valueName: "note"))
    var note: [String] = []

    @Flag(name: .customLong("dry-run"), help: "Only list what would be deleted.")
    var dryRun = false

    @Option(name: .customLong("file"), help: ArgumentHelp("Only delete this blob file (<name>.<kind>.age). Repeatable.",
                                                          valueName: "name"))
    var files: [String] = []

    @OptionGroup var collection: CollectionOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let stateURL = BlobCollectorState.defaultURL(vaultId: vault.vaultId)
        var state = try BlobCollectorState.load(from: stateURL, vaultId: vault.vaultId)
        if state.vaultId != vault.vaultId { state = BlobCollectorState(vaultId: vault.vaultId) }
        let ids = try notes(note, in: vault)
        let now = Date()
        var reports: [BlobCollectionReport] = []
        let only = files.isEmpty ? nil : Set(files)
        for id in ids {
            var records = state.notes[noteName(id)] ?? [:]
            reports.append(try vault.collectBlobs(note: id, records: &records, only: only, now: now,
                                                  retention: collection.retention * 86400, dryRun: dryRun))
            state.notes[noteName(id)] = records.isEmpty ? nil : records
        }
        if !dryRun { try state.save(to: stateURL) }
        let (after, titles) = try storageReport(vault, ids, state: state, retention: collection.retention, now: now,
                                                cache: cache.cache(for: vault))
        let storage = StorageOut(after, titles: titles, now: now)
        if output.json {
            struct Out: Encodable { var notes: [CollectionOut]; var storage: StorageOut }
            try output.emitJSON(Out(notes: reports.map(CollectionOut.init), storage: storage))
        } else {
            for r in reports {
                if let b = r.blocked { printError("\(noteName(r.note)): not collected: \(b)") }
                for f in r.deleted { print("\(dryRun ? "would delete" : "deleted") \(noteName(r.note))/att/\(f)") }
                for (f, why) in r.failures.sorted(by: { $0.key < $1.key }) {
                    printError("\(noteName(r.note))/att/\(f): not deleted, cannot be verified: \(why)")
                }
            }
            let deleted = reports.reduce(0) { $0 + $1.deleted.count }
            let waiting = reports.reduce(0) { $0 + $1.unused.count } - deleted
            output.info("\(dryRun ? "Would delete" : "Deleted") \(deleted) blob(s); \(waiting) unused blob(s) inside the retention window.")
            output.info(storage.line)
        }
        if reports.contains(where: { $0.blocked != nil || !$0.failures.isEmpty }) {
            throw ExitCode(ExitStatus.unhealthy)
        }
    }
}

// MARK: - repair

struct BlobsRepair: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Re-encrypt and rename blobs a recipient change left behind (old name, old recipients, wrong kind).",
        discussion: """
            Only authentic blobs are rewritten: their name verifies under the vault secret, or their content \
            is referenced by a verified revision of their note. Other files are listed and left alone. Exit 3 \
            when something could not be repaired.
            """
    )

    @Argument(help: ArgumentHelp("Notes (id or title). Default: every note.", valueName: "note"))
    var note: [String] = []

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        var reports: [BlobRepairReport] = []
        for id in try notes(note, in: vault) { reports.append(try vault.repairBlobs(note: id)) }
        if output.json {
            struct Out: Encodable {
                var note: String; var blocked: String?; var repaired: [String: [String]]
                var leftAlone: [String]; var failures: [String: String]
            }
            try output.emitJSON(reports.map {
                Out(note: noteName($0.note), blocked: $0.blocked, repaired: $0.repaired, leftAlone: $0.leftAlone,
                    failures: $0.failures)
            })
        } else {
            for r in reports {
                let n = noteName(r.note)
                if let b = r.blocked { printError("\(n): \(b)") }
                for (old, new) in r.repaired.sorted(by: { $0.key < $1.key }) {
                    print("repaired \(n)/att/\(old) -> \(new.joined(separator: ", "))")
                }
                for f in r.leftAlone { printError("\(n)/att/\(f): left alone (name does not verify, content not referenced)") }
                for (f, why) in r.failures.sorted(by: { $0.key < $1.key }) { printError("\(n)/att/\(f): \(why)") }
            }
            output.info("Repaired \(reports.reduce(0) { $0 + $1.repaired.count }) blob(s).")
        }
        if reports.contains(where: { $0.blocked != nil || !$0.failures.isEmpty || !$0.leftAlone.isEmpty }) {
            throw ExitCode(ExitStatus.unhealthy)
        }
    }
}
