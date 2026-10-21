import Age
import Crypto
import Foundation

/// The result of `Vault.verify()`.
public struct VerifyReport: Hashable, Sendable {
    /// Per-file outcome.
    public enum Status: String, Hashable, Sendable, CaseIterable {
        /// Decrypted, tag verified, decoded, encrypted in one stanza to the
        /// vault identity. For `keys/` files: a well-named passphrase copy
        /// (not decrypted; that needs its passphrase). For `epochs/`: the
        /// current epoch's record, whose hash and chain check.
        case ok
        /// The inner tag does not match (format.md §4).
        case tagMismatch
        /// age decryption failed, or the file could not be read.
        case undecryptable
        /// Not a valid framed gzip body.
        case corruptBody
        /// The JSON is not a revision of this note under this name.
        case undecodable
        /// Readable and verified, but its age header holds other stanzas than
        /// the one to the vault identity (format.md §15.2).
        case extraStanzas
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
        /// Under an earlier epoch's key and not taken by the acceptance rule (key-hierarchy design §5.3):
        /// set aside, never placed. Healthy (Repair lists it); written by a removed device, or by a listed one
        /// that has not caught up yet.
        case setAside
        /// Under a key whose epoch record has not arrived (design §5.3 rule 3). Healthy; it waits.
        case pending

        /// True for a status that makes the vault unhealthy. `ok`, `unknownFile`,
        /// `notChecked`, `unreferenced` and `newer` are healthy.
        public var isProblem: Bool {
            switch self {
            case .ok, .unknownFile, .notChecked, .unreferenced, .newer, .setAside, .pending: return false
            case .tagMismatch, .undecryptable, .corruptBody, .undecodable, .extraStanzas, .unlistable,
                 .missing, .invalid: return true
            }
        }
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
    /// How `vault.json` checked (design §4.3). A refused list is also a manifest problem.
    public var list: ListStatus = .notChecked
    /// Every entry examined, in walk order.
    public var files: [FileResult] = []

    /// True when `vault.json` passed every check.
    public var manifestOK: Bool { manifestProblems.isEmpty }

    /// Number of entries per status.
    public var counts: [Status: Int] {
        files.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }

    /// True when the manifest is fine and every entry is `ok`, `unknownFile`,
    /// `unreferenced` or (vault that cannot read) `notChecked`.
    public var isHealthy: Bool {
        manifestOK && files.allSatisfy { !$0.status.isProblem }
    }
}

extension VerifyReport.Status {
    init(_ e: RevisionReadError) {
        switch e {
        case .unreadable, .undecryptable: self = .undecryptable
        case .tagMismatch: self = .tagMismatch
        case .corruptBody: self = .corruptBody
        case .undecodable: self = .undecodable
        case .newer: self = .newer
        case .setAside: self = .setAside
        case .pending: self = .pending
        }
    }
}

extension Vault {
    /// Walks the whole vault: re-reads and checks `vault.json`, then reads
    /// and verifies every revision file and every attachment blob (each
    /// decrypted and hashed in full, streaming). Never throws; one bad file
    /// is one line of the report.
    public func verify() -> VerifyReport { verify(notes: nil) }

    /// `verify()` restricted to the given notes (the manifest, `keys/`,
    /// `epochs/` and `joins/` are still checked; other notes are skipped, not
    /// listed).
    public func verify(notes only: Set<UUID>?) -> VerifyReport {
        let wanted = only.map { Set($0.map { $0.uuidString.lowercased() }) }
        var report = VerifyReport()
        report.manifestProblems = manifestProblems()
        report.list = listStatus
        if let problem = listStatus.problem { report.manifestProblems.append(problem.description) }

        /// Lists `dir`, recording an `unlistable` entry instead of throwing.
        func list(_ dir: URL, as path: String) -> [String] {
            do { return try FileIO.entries(dir) } catch {
                report.files.append(.init(path: path, status: .unlistable, detail: "\(error)"))
                return []
            }
        }

        var settingsFile = false
        var inboxFolder = false
        var notebooksFolder = false
        for entry in list(url, as: ".") where ![Self.manifestName, Self.keysName, Self.notesName,
                                                Self.epochsName, Self.joinsName].contains(entry) {
            if entry == CaptureFile.folderName, FileIO.isDirectory(inboxURL) {
                inboxFolder = true
                continue
            }
            if entry == SharedSettings.fileName, !FileIO.isDirectory(sharedSettingsURL) {
                settingsFile = true
                continue
            }
            if entry == NotebookRecords.folderName, FileIO.isDirectory(notebooksURL) {
                notebooksFolder = true
                continue
            }
            report.files.append(.init(path: entry, status: .unknownFile, detail: nil))
        }
        for entry in list(keysURL, as: Self.keysName) {
            let ok = Self.isPassphraseCopyName(entry) && !FileIO.isDirectory(keysURL.appendingPathComponent(entry))
            report.files.append(.init(path: "\(Self.keysName)/\(entry)", status: ok ? .ok : .unknownFile,
                                      detail: nil))
        }
        if FileIO.isDirectory(epochsURL) {
            for entry in list(epochsURL, as: Self.epochsName) { report.files.append(verifyEpochRecord(entry)) }
        }
        if FileIO.isDirectory(joinsURL) {
            for entry in list(joinsURL, as: Self.joinsName) { report.files.append(verifyJoinRequest(entry)) }
        }
        let expected = Self.expectedStanzas
        let notReadable = secret == nil ? "vault locked" : nil
        if settingsFile { report.files.append(verifySharedSettings(notReadable: notReadable, expected: expected)) }
        if notebooksFolder, only == nil {
            for entry in list(notebooksURL, as: NotebookRecords.folderName) {
                report.files.append(verifyNotebookRecord(entry, notReadable: notReadable, expected: expected))
            }
        }
        // The inbox is not part of a note: checked by a whole-vault verify only.
        if inboxFolder, only == nil {
            verifyInbox(entries: list(inboxURL, as: CaptureFile.folderName), notReadable: notReadable, expected: expected,
                        into: &report)
        }
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
                    let data = try readFile(file, maxBytes: BoundedRead.maxRevisionBytes)
                    let json = try revisionJSON(data, note: note, name: name, secret: secret)
                    let rev = try Self.decodeRevisionJSON(json, note: note, name: name, detail: .full)
                    refs += (try? BlobReferenceScan.references(inDecoded: json)) ?? []
                    let stanzas = (try? Self.stanzaCounts(data)) ?? [:]
                    if let newer = rev.newer {
                        if let id = UUID(uuidString: note) { noteNewerContent(in: id) }
                        report.files.append(.init(path: path, status: .newer, detail: newer.summary))
                    } else if stanzas != expected {
                        report.files.append(.init(path: path, status: .extraStanzas,
                                                  detail: "stanzas: \(Self.describe(stanzas)); the vault identity needs: "
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

    /// The `verify` line of `settings.age` (format.md §13): read within its
    /// limit, decrypted, tag-checked (under the previous secret too during a
    /// rewrap) and decoded as `readSharedSettings` does, then its stanzas
    /// compared with the recipients. A file for a newer reader is `ok`.
    private func verifySharedSettings(notReadable: String?, expected: [String: Int]) -> VerifyReport.FileResult {
        let path = SharedSettings.fileName
        guard notReadable == nil else { return .init(path: path, status: .notChecked, detail: notReadable) }
        do {
            let data = try readFile(sharedSettingsURL, maxBytes: SharedSettings.maxFileBytes)
            _ = try openSharedSettings(data, allowNewerReader: true)
            let stanzas = (try? Self.stanzaCounts(data)) ?? [:]
            guard stanzas == expected else {
                return .init(path: path, status: .extraStanzas,
                             detail: "stanzas: \(Self.describe(stanzas)); the vault identity needs: " + Self.describe(expected))
            }
            return .init(path: path, status: .ok, detail: nil)
        } catch let e as SharedSettingsError {
            let status: VerifyReport.Status
            switch e {
            case .framing(.tagMismatch): status = .tagMismatch
            case .framing: status = .corruptBody
            case .undecryptable: status = .undecryptable
            case .setAside: status = .setAside
            case .pending: status = .pending
            case .tooLarge, .invalid, .clockExhausted, .needsNewerReader: status = .undecodable
            }
            return .init(path: path, status: status, detail: "\(e)")
        } catch {
            return .init(path: path, status: .undecryptable, detail: "\(error)")
        }
    }

    /// The `verify` line of one entry of `notebooks/` (format.md §14): a record
    /// is read within its limit, opened as `readNotebookRecords` does and its
    /// stanzas compared with the recipients; other names are unknown files.
    private func verifyNotebookRecord(_ name: String, notReadable: String?, expected: [String: Int]) -> VerifyReport.FileResult {
        let path = "\(NotebookRecords.folderName)/\(name)"
        let file = notebooksURL.appendingPathComponent(name)
        guard NotebookRecords.id(ofFileName: name) != nil, !FileIO.isDirectory(file) else {
            return .init(path: path, status: .unknownFile, detail: nil)
        }
        guard notReadable == nil else { return .init(path: path, status: .notChecked, detail: notReadable) }
        do {
            let data = try readFile(file, maxBytes: NotebookRecords.maxFileBytes)
            _ = try openNotebookRecord(data, fileName: name)
            let stanzas = (try? Self.stanzaCounts(data)) ?? [:]
            guard stanzas == expected else {
                return .init(path: path, status: .extraStanzas,
                             detail: "stanzas: \(Self.describe(stanzas)); the vault identity needs: " + Self.describe(expected))
            }
            return .init(path: path, status: .ok, detail: nil)
        } catch let e as NotebookRecordError {
            let status: VerifyReport.Status
            switch e {
            case .framing(.tagMismatch): status = .tagMismatch
            case .framing: status = .corruptBody
            case .undecryptable: status = .undecryptable
            case .setAside: status = .setAside
            case .pending: status = .pending
            case .tooLarge, .invalid: status = .undecodable
            }
            return .init(path: path, status: status, detail: "\(e)")
        } catch {
            return .init(path: path, status: .undecryptable, detail: "\(error)")
        }
    }

    /// The inbox part of `verify` (format.md §11.2): every capture or
    /// transcript file is decrypted and its tag checked under the capture
    /// key ring, streamed as adoption does, and its stanzas against the
    /// recipients; other names are unknown files. A file that fails is
    /// `invalid` (it is never adopted); one this vault cannot check (locked,
    /// or a device list that does not check) is `notChecked`.
    private func verifyInbox(entries: [String], notReadable: String?, expected: [String: Int],
                             into report: inout VerifyReport) {
        var ring: [CaptureKeyEntry]?
        var ringProblem: String?
        for entry in entries {
            let path = "\(CaptureFile.folderName)/\(entry)"
            let file = inboxURL.appendingPathComponent(entry)
            guard let parsed = CaptureFile.parse(name: entry), !FileIO.isDirectory(file) else {
                report.files.append(.init(path: path, status: .unknownFile, detail: nil))
                continue
            }
            if let notReadable {
                report.files.append(.init(path: path, status: .notChecked, detail: notReadable))
                continue
            }
            if ring == nil, ringProblem == nil {
                do {
                    try requireTrustedList()
                    ring = try captureKeyRing()
                } catch {
                    ringProblem = "\(error)"
                }
            }
            guard let ring else {
                report.files.append(.init(path: path, status: .notChecked, detail: ringProblem))
                continue
            }
            do {
                _ = try verifyInboxFile(file, name: entry, kind: parsed.kind, ring: ring)
                let stanzas = Self.stanzaCounts(blob: file)
                if stanzas != expected {
                    report.files.append(.init(path: path, status: .extraStanzas,
                                              detail: "stanzas: \(Self.describe(stanzas)); the vault identity needs: "
                                                  + Self.describe(expected)))
                } else {
                    report.files.append(.init(path: path, status: .ok, detail: nil))
                }
            } catch let e as CaptureError {
                report.files.append(.init(path: path, status: .invalid, detail: e.description))
            } catch {
                report.files.append(.init(path: path, status: .undecryptable, detail: "\(error)"))
            }
        }
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
                let header = try readAnyAcceptedBlob(url, note: UUID(uuidString: note) ?? UUID(), maxContent: BlobRef.maxSize)
                let stanzas = Self.stanzaCounts(blob: url)
                let used = kinds[header.sha256]?.contains(parsed.kind) == true
                if used { resolved.insert("\(header.sha256)/\(parsed.kind.rawValue)") }
                if stanzas != expected {
                    report.files.append(.init(path: path, status: .extraStanzas,
                                              detail: "stanzas: \(Self.describe(stanzas)); the vault identity needs: "
                                                  + Self.describe(expected)))
                } else if !used {
                    report.files.append(.init(path: path, status: .unreferenced, detail: "content \(header.sha256)"))
                } else {
                    report.files.append(.init(path: path, status: .ok, detail: nil))
                }
            } catch BlobError.setAside(let reason) {
                report.files.append(.init(path: path, status: .setAside, detail: reason.text))
            } catch BlobError.pending {
                report.files.append(.init(path: path, status: .pending, detail: "\(BlobError.pending)"))
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

    /// The stanzas every vault file has (format.md §15.2): one, to the vault identity.
    static let expectedStanzas = ["mlkem768x25519": 1]

    /// `recovery-<64 lowercase hex>.key.age` (format.md §15.11).
    static func isPassphraseCopyName(_ name: String) -> Bool {
        guard name.hasPrefix("recovery-"), name.hasSuffix(".key.age") else { return false }
        let hex = name.dropFirst("recovery-".count).dropLast(".key.age".count)
        return hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// The `verify` line of one entry of `epochs/` (format.md §15.6): the current epoch's record must be
    /// there, hash to `epochRecordHash`, open under the key and carry a chain rooted at the vault's root
    /// whose last entry is this epoch. Other names are unknown files (an orphan record included).
    private func verifyEpochRecord(_ name: String) -> VerifyReport.FileResult {
        let path = "\(Self.epochsName)/\(name)"
        guard Self.epochsName + "/" + name == manifest.epochRecord else {
            // An earlier epoch's record on the verified chain (its key opens it as readers need it); any other
            // name, an orphan record included, is an unknown file (design §5.2 step 4).
            if let chain = verifiedChain?.entries.dropLast(),
               chain.contains(where: { EpochRecord.fileName(epoch: $0.epoch, epochId: $0.epochId) == name }) {
                return .init(path: path, status: .ok, detail: "an earlier epoch's record")
            }
            return .init(path: path, status: .unknownFile, detail: nil)
        }
        do {
            let data = try readFile(epochsURL.appendingPathComponent(name), maxBytes: EpochRecord.maxBytes)
            guard Data(SHA256.hash(data: data)) == manifest.epochRecordHash else {
                return .init(path: path, status: .invalid, detail: "its hash is not vault.json's epochRecordHash")
            }
            guard let secret else { return .init(path: path, status: .notChecked, detail: "vault locked") }
            let record = try EpochRecord.open(data, key: secret, vaultId: vaultId, epoch: manifest.epoch)
            _ = try EpochChain.verify(record.chain, vaultId: vaultId, root: manifest.root)
            guard record.chain.last?.epochId == manifest.epochId else {
                return .init(path: path, status: .invalid, detail: "its chain does not end at this epoch")
            }
            return .init(path: path, status: .ok, detail: nil)
        } catch {
            return .init(path: path, status: .invalid, detail: "\(error)")
        }
    }

    /// The `verify` line of one entry of `joins/` (format.md §15.12): a request that parses and names
    /// this vault is `ok`; anything else under a request's name is `invalid` (home deletes it).
    private func verifyJoinRequest(_ name: String) -> VerifyReport.FileResult {
        let path = "\(Self.joinsName)/\(name)"
        guard name.hasSuffix(".join.json") else { return .init(path: path, status: .unknownFile, detail: nil) }
        do {
            let request = try JoinRequest.parse(try readFile(joinsURL.appendingPathComponent(name), maxBytes: JoinRequest.maxBytes))
            guard request.vaultId == vaultId, request.fileName == name else {
                return .init(path: path, status: .invalid, detail: "not a request of this vault under its own name")
            }
            return .init(path: path, status: .ok, detail: nil)
        } catch {
            return .init(path: path, status: .invalid, detail: "\(error)")
        }
    }

    func manifestProblems() -> [String] {
        let data: Data
        do { data = try readFile(manifestURL, maxBytes: BoundedRead.maxManifestBytes) } catch { return ["vault.json: \(error)"] }
        let m: EpochManifest
        do { m = try Self.readManifest(data) } catch { return ["vault.json: \(error)"] }
        var problems: [String] = []
        // `features` may legitimately grow after open (a later version's writer adds one, format.md §2,
        // §7), and with them `markersTag` and `authorSig`; the label is covered by nothing. Anything else
        // is a change.
        var opened = manifest, now = m
        opened.features = m.features; opened.markersTag = m.markersTag; opened.authorSig = m.authorSig
        opened.label = nil; now.label = nil
        if now != opened { problems.append("vault.json changed on disk since the vault was opened") }
        // Every wrap is an armored age file with one stanza to its key (format.md §15.3).
        for entry in m.keys {
            do {
                let stanzas = try Self.stanzaCounts(try Armor.decode(Data(entry.wrap.utf8)))
                if stanzas != Self.expectedStanzas {
                    problems.append("the wrap of \(entry.id ?? entry.role.rawValue) has stanzas \(Self.describe(stanzas))")
                }
            } catch {
                problems.append("the wrap of \(entry.id ?? entry.role.rawValue) is not an armored age file: \(error)")
            }
        }
        if let secret, !unlockIdentities.isEmpty,
           let mine = m.keys.first(where: { identityRecipients.contains($0.key) }) {
            do {
                let k = try EpochKeyWrap.open(mine.wrap, with: unlockIdentities, vaultId: m.vaultId, epoch: m.epoch)
                if k != secret { problems.append("this device's wrap opens to another key than the one in use") }
            } catch {
                problems.append("this device's wrap: \(error)")
            }
        }
        return problems
    }
}
