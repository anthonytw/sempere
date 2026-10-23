import Foundation

extension VaultError {
    /// The `manifestCorrupt` detail when `vault.json` on disk is no longer the
    /// version this value opened (home changed it meanwhile).
    static let changedSinceOpened = "vault.json changed since it was opened; open the vault again"
    /// The same for its version markers.
    static let markersChangedSinceOpened = "vault.json's version markers changed since it was opened; open the vault again"

    /// True when the vault value is stale (`changedSinceOpened`,
    /// `markersChangedSinceOpened`): opening the vault again and repeating
    /// the operation may succeed.
    public var isChangedSinceOpened: Bool {
        guard case .manifestCorrupt(let detail) = self else { return false }
        return detail == Self.changedSinceOpened || detail == Self.markersChangedSinceOpened
    }
}

extension VaultError: CustomStringConvertible {
    /// A human sentence for each case, for tools that show errors to people.
    public var description: String {
        switch self {
        case .invalidVaultName(let n): return "'\(n)' is not a vault name: a vault directory must end in .sempere"
        case .alreadyExists(let p): return "\(p) already exists"
        case .notAVault(let p): return "\(p) is not a vault (no vault.json)"
        case .manifestCorrupt(let why): return "vault.json is damaged: \(why)"
        case .unsupportedFormat(let f): return "this vault uses format '\(f)', which this version cannot read"
        case .invalidRecipient(let r): return "'\(ListProblem.abbreviate(r))' is not a post-quantum age key (age1pq1...)"
        case .classicRecipient(let r):
            return "\(r.prefix(16))… is a classic X25519 key, which is not quantum-safe; vaults take only "
                + "post-quantum age1pq1... keys"
        case .classicIdentity:
            return "that is a classic X25519 key (AGE-SECRET-KEY-1...), and vaults take only post-quantum keys"
        case .keyNotListed(let why): return why
        case .locked: return "the vault is locked: no key was given"
        case .recoveryKeyReadOnly:
            return "the vault was opened with the recovery key, which reads but never writes: join this device "
                + "(sempere device init) to write"
        case .notHome(let why): return why
        case .deviceAlreadyListed(let id): return "device \(id) is already listed"
        case .deviceNotFound(let q): return "no listed device has the id '\(q)'"
        case .joinRequestRefused(let why): return "join request refused: \(why)"
        case .replyMismatch:
            return "those words are not the home device's reply for this vault: check them, or the vault on this "
                + "storage is not the one the home device approved this device in"
        case .invalidNoteId(let n): return "'\(n)' is not a note id (lowercase UUID)"
        case .seqInUse(let device, let seq): return "device \(device) already has a revision with sequence number \(seq)"
        case .seqOutOfRange(let seq): return "sequence number \(seq) is outside 1...\(RevisionName.maxSeq)"
        case .revision(let name, let inner): return "\(name): \(inner)"
        case .workFactorOutOfRange(let n): return "scrypt work factor \(n) is outside the allowed range 1...20"
        case .workFactorTooHigh: return "the passphrase copy needs more scrypt work than this reader allows"
        case .passphraseCopyMissing: return "the vault holds no passphrase copy of its recovery key (keys/recovery-*.key.age)"
        case .wrongPassphrase: return "wrong passphrase for the recovery key's passphrase copy"
        case .emptyPassphrase: return "the passphrase is empty"
        case .passphraseCopyMalformed(let why): return "the passphrase copy is damaged: \(why)"
        case .interrupted: return "interrupted (test hook)"
        case .fileTooLarge(let path, let limit): return "\(path) is larger than the \(limit)-byte limit"
        case .io(let why): return why
        case .readOnly(let reasons):
            return "this vault is read-only for this version of Sempere: " + reasons.descriptions.joined(separator: "; ")
                + "; update Sempere to change it"
        case .untrustedList(let p):
            return "vault.json does not check on this device (\(p.description)); nothing is written to the vault"
        case .partialCopy(let path):
            return "\(path) is a partial copy of a WebDAV vault (format.md §1.2): fetch the rest first "
                + "(sempere sync webdav <url> --fetch, or a plain sync)"
        case .noteIncomplete(let note):
            return "note \(note) is not completely downloaded yet (partial copy, format.md §1.2); fetch it first "
                + "(sempere sync webdav <url> --fetch --note \(note))"
        case .removedFromVault(let why): return why
        case .ledgerUnreadable(let why): return "this device's write ledger cannot be used (\(why)); nothing was written"
        case .setAsideFailed(let why): return "a file could not be set aside (\(why)); nothing was replaced"
        case .epochChangeRefused(let why): return why
        }
    }
}

extension BlobError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .invalidReference: return "malformed blob reference (sha256 or size)"
        case .tooLarge(let n): return "\(n) bytes is over the 1 GiB attachment limit"
        case .missing(let p): return "attachment missing: \(p)"
        case .unreadable(let why): return "cannot read the attachment: \(why)"
        case .undecryptable(let why): return "cannot decrypt the attachment: \(why)"
        case .badMagic: return "the decrypted file is not an attachment blob (bad magic)"
        case .unsupportedVersion(let v): return "unsupported blob version \(v)"
        case .truncated: return "the attachment is truncated"
        case .lengthOutOfRange(let l): return "the attachment claims \(l) bytes, over the 1 GiB limit"
        case .nonZeroPadding: return "the attachment's padding is not zero"
        case .contentHashMismatch: return "the attachment's content does not match its hash"
        case .nameMismatch:
            return "the attachment's file name does not match its content under this vault's key "
                + "(renamed, planted, or named under another key: see `sempere blobs repair`)"
        case .referenceMismatch: return "the attachment is not the content the note references"
        case .contentTooLarge(let limit): return "the attachment is larger than \(limit) bytes"
        case .sourceChanged: return "the source file changed while it was being stored"
        case .setAside(let reason): return "the attachment is set aside: \(reason.text)"
        case .pending: return "the attachment waits for a device-change record (its key is not known yet)"
        }
    }
}

extension RevisionReadError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .unreadable(let why): return "cannot read the file: \(why)"
        case .undecryptable(let why): return "cannot decrypt: \(why)"
        case .tagMismatch: return "tag mismatch: the file was altered, moved or written under another key"
        case .corruptBody(let why): return "damaged body: \(why)"
        case .undecodable(let why): return "cannot decode the revision: \(why)"
        case .newer(let why): return "written by a newer version of Sempere (\(why)): update Sempere to read it"
        case .setAside(let reason): return "set aside: \(reason.text)"
        case .pending: return "waiting for a device-change record (its key is not known yet)"
        }
    }
}

extension NoteLogError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .noRevisions: return "the note has no revisions"
        case .mixedNotes(let a, let b): return "revisions of two notes were mixed (\(a), \(b))"
        case .conflictingRevisions(let device, let seq):
            return "device \(device) has two different revisions with sequence number \(seq)"
        case .notADelta(let n): return "\(n) is not a delta"
        }
    }
}

extension BodyFramingError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .tooShort: return "the decrypted body is too short to be a Sempere file"
        case .badMagic: return "the decrypted body is not a Sempere file (bad magic)"
        case .unsupportedVersion(let v): return "unsupported body version \(v)"
        case .tagMismatch: return "tag mismatch: the file was altered, moved or belongs to another vault"
        }
    }
}

extension HistoryError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .unknownRevision(let q): return "no revision of this note matches '\(q)'"
        case .ambiguousRevision(let q, let names):
            return "'\(q)' matches several revisions: \(names.map(\.filename).joined(separator: ", "))"
        case .incompleteHistory(let n):
            return "the note as of \(n.filename) cannot be rebuilt: earlier revisions were compacted away or are unreadable"
        }
    }
}

extension GzipError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .deflate(let code): return "compression failed (zlib error \(code))"
        case .inflate: return "not a valid gzip stream"
        case .tooLarge(let limit): return "the decompressed data is larger than the limit of \(limit) bytes"
        }
    }
}

extension PublishedSummariesError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .damaged(let why): return "the published summaries file is damaged: \(why)"
        case .cannotSign(let why): return "this device cannot sign its published summaries file: \(why)"
        }
    }
}

extension LocalCacheError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self { case .damaged(let why): return "the local cache is damaged: \(why)" }
    }
}

extension SummaryCacheError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self { case .damaged(let why): return "the summary cache is damaged: \(why)" }
    }
}

extension NotebookRecordError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .tooLarge: return "the notebook records file is too large"
        case .undecryptable(let why): return "the notebook records file cannot be decrypted: \(why)"
        case .framing(let e): return "the notebook records file does not check: \(e)"
        case .invalid(let why): return "the notebook records file is not valid: \(why)"
        case .setAside(let reason): return "the notebook record is set aside: \(reason.text)"
        case .pending: return "the notebook record waits for a device-change record (its key is not known yet)"
        }
    }
}

extension SharedSettingsError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .tooLarge: return "the settings file is too large"
        case .invalid(let why): return "the settings file is not valid: \(why)"
        case .undecryptable(let why): return "the settings file cannot be decrypted: \(why)"
        case .framing(let e): return "the settings file does not check: \(e)"
        case .clockExhausted(let key): return "the setting \(key) cannot be written: its time would pass the largest the format allows"
        case .needsNewerReader(let min): return "the settings need a newer reader (settings reader \(min) or later)"
        case .setAside(let reason): return "the settings file is set aside: \(reason.text)"
        case .pending: return "the settings file waits for a device-change record (its key is not known yet)"
        }
    }
}

extension CompactionError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .unreadableRevision(let why): return "a revision cannot be read, so nothing was deleted: \(why)"
        case .cannotProtect(let why): return "a restore point could not be protected, so nothing was written: \(why)"
        case .stateWouldChange: return "the plan would change the note's state, so nothing was done"
        case .versionWouldChange(let name): return "the plan would change the kept version \(name), so nothing was done"
        }
    }
}

extension ItemChangeError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .immutableField(let f): return "the field \(f) is set once and cannot be changed"
        case .nullNotAllowed(let f): return "the field \(f) cannot be cleared"
        case .invalidValue(let why): return "invalid value: \(why)"
        }
    }
}

extension ItemEditError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .invalidItem(let why): return "invalid item: \(why)"
        case .duplicateID(let id): return "the page already has an item \(id.uuidString.lowercased())"
        }
    }
}
