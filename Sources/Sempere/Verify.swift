import Age
import Foundation

/// The result of `Vault.verify()`.
public struct VerifyReport: Hashable, Sendable {
    /// Per-file outcome.
    public enum Status: String, Hashable, Sendable, CaseIterable {
        /// Decrypted, tag verified, decoded, encrypted to the current
        /// recipient count. For `keys/` files: a well-named identity file
        /// (not decrypted; that needs its passphrase).
        case ok
        /// The inner tag does not match (format.md §4).
        case tagMismatch
        /// age decryption failed, or the file could not be read.
        case undecryptable
        /// Not a valid framed gzip body.
        case corruptBody
        /// The JSON is not a revision of this note under this name.
        case undecodable
        /// Readable and verified, but encrypted to a different number of
        /// recipients than `vault.json` lists: an unfinished recipient change.
        case staleRecipients
        /// Not part of the format; ignored, never deleted.
        case unknownFile
        /// A directory that exists but could not be listed; its contents are
        /// unknown, so the vault is not healthy.
        case unlistable
        /// The vault cannot read (locked, or no identities), so the file was
        /// not decrypted.
        case notChecked
        /// An attachment blob some revision of its note references is not
        /// in the note's `att/` (format.md §8.1.4, §8.5.2).
        case missing
        /// An attachment blob that fails to decrypt or verify: framing,
        /// padding, content hash, or a name that does not verify (format.md
        /// §8.1.4).
        case invalid
        /// A valid attachment blob that no revision of its note references:
        /// healthy; collection may remove it later (format.md §8.1.6).
        case unreferenced
        /// A revision written by a newer version (format.md §7.2): read
        /// leniently (the detail says what was skipped), or not readable by
        /// this version at all. Healthy; the vault is read-only.
        case newer
    }

    /// One file or directory.
    public struct FileResult: Hashable, Sendable {
        /// Path relative to the vault directory, `/`-separated.
        public var path: String
        /// What was found: `ok`, a failure stage, or why it was not checked.
        public var status: Status
        /// Human-readable detail for anything not `ok`.
        public var detail: String?
    }

    /// Problems found in `vault.json`; empty when it is fine.
    public var manifestProblems: [String] = []
    /// How the recipients list checked (format.md §2.1). A tampered list is
    /// also a manifest problem; an untagged one is not (writers upgrade it).
    public var recipients: RecipientsStatus = .notChecked
    /// Every entry examined, in walk order.
    public var files: [FileResult] = []
    /// True while a recipient change is unfinished.
    public var rewrapPending = false
    /// Why the pending rewrap journal could not be read, if it could not.
    public var journalProblem: String?

    /// True when `vault.json` passed every check.
    public var manifestOK: Bool { manifestProblems.isEmpty }

    /// Number of entries per status.
    public var counts: [Status: Int] {
        files.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }

    /// True when the manifest and any pending journal are fine and every
    /// entry is `ok`, `unknownFile`, `unreferenced` or (vault that cannot
    /// read) `notChecked`.
    public var isHealthy: Bool {
        manifestOK && journalProblem == nil
            && files.allSatisfy { [.ok, .unknownFile, .notChecked, .unreferenced, .newer].contains($0.status) }
    }
}

extension VerifyReport.Status {
    init(_ e: RevisionReadError) {
        switch e {
        case .unreadable, .undecryptable: self = .undecryptable
        case .tagMismatch, .tagMismatchJournalUnreadable: self = .tagMismatch
        case .corruptBody: self = .corruptBody
        case .undecodable: self = .undecodable
        case .newer: self = .newer
        }
    }
}

extension Vault {
    /// Walks the whole vault: re-reads and checks `vault.json`, then reads
    /// and verifies every revision file and every attachment blob (each
    /// decrypted and hashed in full, streaming). Never throws; one bad file
    /// is one line of the report.
    public func verify() -> VerifyReport { verify(notes: nil) }

    /// `verify()` restricted to the given notes (the manifest, journal and
    /// `keys/` are still checked; other notes are skipped, not listed).
    public func verify(notes only: Set<UUID>?) -> VerifyReport {
        let wanted = only.map { Set($0.map { $0.uuidString.lowercased() }) }
        var report = VerifyReport()
        report.rewrapPending = pendingRewrap
        report.journalProblem = pendingRewrap ? journalProblem : nil
        report.manifestProblems = manifestProblems()
        report.recipients = recipientsStatus
        if let problem = recipientsStatus.problem { report.manifestProblems.append(problem.description) }

        /// Lists `dir`, recording an `unlistable` entry instead of throwing.
        func list(_ dir: URL, as path: String) -> [String] {
            do { return try FileIO.entries(dir) } catch {
                report.files.append(.init(path: path, status: .unlistable, detail: "\(error)"))
                return []
            }
        }

        for entry in list(url, as: ".") where ![Self.manifestName, Self.keysName, Self.notesName,
                                                Self.journalName].contains(entry) {
            report.files.append(.init(path: entry, status: .unknownFile, detail: nil))
        }
        for entry in list(keysURL, as: Self.keysName) {
            let ok = IdentityFile.isKeyFileName(entry)
                && !FileIO.isDirectory(keysURL.appendingPathComponent(entry))
            report.files.append(.init(path: "\(Self.keysName)/\(entry)", status: ok ? .ok : .unknownFile,
                                      detail: nil))
        }
        let expected = Self.expectedStanzas((try? ageRecipients()) ?? [])
        // A legacy vault is not checked file by file: its notes are not to be
        // read before the migration (format.md §3.3.2).
        let legacy = (try? requireMigrated()) == nil
        if legacy {
            report.manifestProblems.append("legacy vault: classic X25519 recipient(s) "
                + classicRecipients.joined(separator: ", ") + "; migrate first (format.md §3.3.2)")
        }
        let notReadable = legacy ? "legacy vault: migrate first"
            : secret == nil ? "vault locked" : identities.isEmpty ? "no identities" : nil
        for note in list(notesURL, as: Self.notesName) where wanted?.contains(note) ?? true {
            let dir = notesURL.appendingPathComponent(note)
            let base = "\(Self.notesName)/\(note)"
            guard Self.isNoteDirectoryName(note), FileIO.isDirectory(dir) else {
                report.files.append(.init(path: base, status: .unknownFile, detail: nil))
                continue
            }
            var refs: [FoundBlobReference] = []
            var hasAttachments = false
            for entry in list(dir, as: base) {
                let path = "\(base)/\(entry)"
                let file = dir.appendingPathComponent(entry)
                if entry == Self.attachmentsName, FileIO.isDirectory(file) {
                    hasAttachments = true
                    continue
                }
                guard let name = RevisionName(entry), name.filename == entry, !FileIO.isDirectory(file) else {
                    report.files.append(.init(path: path, status: .unknownFile, detail: nil))
                    continue
                }
                guard let secret, notReadable == nil else {
                    report.files.append(.init(path: path, status: .notChecked, detail: notReadable))
                    continue
                }
                do {
                    let data = try FileIO.read(file, maxBytes: BoundedRead.maxRevisionBytes)
                    let json = try revisionJSON(data, note: note, name: name, secret: secret)
                    let rev = try Self.decodeRevisionJSON(json, note: note, name: name, detail: .full)
                    refs += (try? BlobReferenceScan.references(in: json)) ?? []
                    let stanzas = (try? Self.stanzaCounts(data)) ?? [:]
                    if let newer = rev.newer {
                        if let id = UUID(uuidString: note) { noteNewerContent(in: id) }
                        report.files.append(.init(path: path, status: .newer, detail: newer.summary))
                    } else if stanzas != expected {
                        report.files.append(.init(path: path, status: .staleRecipients,
                                                  detail: "stanzas: \(Self.describe(stanzas)); recipients need: "
                                                      + Self.describe(expected)))
                    } else {
                        report.files.append(.init(path: path, status: .ok, detail: nil))
                    }
                } catch let e as RevisionReadError {
                    if case .newer = e, let id = UUID(uuidString: note) { noteNewerContent(in: id) }
                    report.files.append(.init(path: path, status: .init(e), detail: "\(e)"))
                } catch {
                    report.files.append(.init(path: path, status: .undecryptable, detail: "\(error)"))
                }
            }
            verifyBlobs(note: note, base: base, present: hasAttachments, references: refs,
                        notReadable: notReadable, expected: expected, into: &report)
        }
        return report
    }

    /// The blob part of `verify` for one note: every file in `att/`, then
    /// every reference with no file (format.md §8.1.4).
    private func verifyBlobs(note: String, base: String, present: Bool, references: [FoundBlobReference],
                             notReadable: String?, expected: [String: Int], into report: inout VerifyReport) {
        let att = notesURL.appendingPathComponent(note).appendingPathComponent(Self.attachmentsName)
        let attPath = "\(base)/\(Self.attachmentsName)"
        var entries: [String] = []
        if present {
            do { entries = try FileIO.entries(att) } catch {
                report.files.append(.init(path: attPath, status: .unlistable, detail: "\(error)"))
            }
        }
        let kinds = Dictionary(grouping: references.filter { Hex.decode($0.sha256) != nil }, by: \.sha256)
            .mapValues { Set($0.map(\.kind)) }
        var resolved = Set<String>()   // "<sha256>/<kind>" of files that verified
        for entry in entries {
            let path = "\(attPath)/\(entry)"
            let url = att.appendingPathComponent(entry)
            guard let parsed = BlobName.parse(entry), !FileIO.isDirectory(url) else {
                report.files.append(.init(path: path, status: .unknownFile, detail: nil))
                continue
            }
            if let notReadable {
                report.files.append(.init(path: path, status: .notChecked, detail: notReadable))
                continue
            }
            do {
                let (header, _) = try Self.readBlobFile(url, identities: identities, secrets: blobSecrets, expected: nil,
                                                        maxContent: BlobRef.maxSize)
                let stanzas = Self.stanzaCounts(blob: url)
                let used = kinds[header.sha256]?.contains(parsed.kind) == true
                if used { resolved.insert("\(header.sha256)/\(parsed.kind.rawValue)") }
                if stanzas != expected {
                    report.files.append(.init(path: path, status: .staleRecipients,
                                              detail: "stanzas: \(Self.describe(stanzas)); recipients need: "
                                                  + Self.describe(expected)))
                } else if !used {
                    report.files.append(.init(path: path, status: .unreferenced, detail: "content \(header.sha256)"))
                } else {
                    report.files.append(.init(path: path, status: .ok, detail: nil))
                }
            } catch {
                report.files.append(.init(path: path, status: .invalid, detail: "\(error)"))
            }
        }
        guard notReadable == nil, let secret else { return }
        var reported = Set<String>()
        for r in references {
            guard let ref = r.ref, let digest = ref.digest else { continue }
            let key = "\(ref.sha256)/\(ref.kind.rawValue)"
            guard !resolved.contains(key), reported.insert(key).inserted else { continue }
            let name = BlobName.fileName(name: BlobName.name(digest: digest, secret: secret), kind: ref.kind)
            report.files.append(.init(path: "\(attPath)/\(name)", status: .missing,
                                      detail: "referenced \(ref.type) blob \(ref.sha256) (\(ref.size) bytes) "
                                          + (entries.contains(name) ? "does not verify" : "is not there")))
        }
    }

    /// Stanza counts of a blob file's age header (empty when unreadable).
    static func stanzaCounts(blob url: URL) -> [String: Int] {
        guard let header = try? AgeFile.readHeader(contentsOf: url) else { return [:] }
        var counts: [String: Int] = [:]
        for s in header.stanzas { counts[s.type, default: 0] += 1 }
        return counts
    }

    func manifestProblems() -> [String] {
        let data: Data
        do { data = try FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes) } catch { return ["vault.json: \(error)"] }
        let m: VaultManifest
        do { m = try Self.readManifest(data) } catch { return ["vault.json: \(error)"] }
        var problems: [String] = []
        // `features` may legitimately grow after open (a blob writer adds
        // `attachments`, format.md §2), and with them `markersTag` (§2.1);
        // anything else is a change.
        var opened = manifest
        opened.features = m.features
        opened.markersTag = m.markersTag
        if m != opened { problems.append("vault.json changed on disk since the vault was opened") }

        // The secret must be armored age encrypted to exactly the recipients.
        do {
            let binary = try Armor.decode(Data(m.vaultSecret.utf8))
            let stanzas = try Self.stanzaCounts(binary)
            let expected = Self.expectedStanzas(try m.recipients.map { try NativeRecipient(string: $0.key) })
            if stanzas != expected {
                problems.append("vaultSecret has stanzas \(Self.describe(stanzas)) for recipients needing "
                    + Self.describe(expected))
            }
        } catch {
            problems.append("vaultSecret is not an armored age file: \(error)")
        }
        if !identities.isEmpty {
            do {
                let s = try Self.decryptSecret(m.vaultSecret, with: identities)
                if let secret, s != secret { problems.append("vaultSecret differs from the one in use") }
            } catch {
                problems.append("vaultSecret: \(error)")
            }
        }
        return problems
    }
}
