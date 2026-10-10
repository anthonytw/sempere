import Foundation

extension VaultError: CustomStringConvertible {
    /// A human sentence for each case, for tools that show errors to people.
    public var description: String {
        switch self {
        case .invalidVaultName(let n): return "'\(n)' is not a vault name: a vault directory must end in .sempere"
        case .alreadyExists(let p): return "\(p) already exists"
        case .notAVault(let p): return "\(p) is not a vault (no vault.json)"
        case .manifestCorrupt(let why): return "vault.json is damaged: \(why)"
        case .unsupportedFormat(let f): return "this vault uses format '\(f)', which this version cannot read"
        case .noRecipients: return "a vault needs at least one recipient"
        case .invalidRecipient(let r): return "'\(r)' is not an age recipient (age1...)"
        case .classicRecipient(let r):
            return "\(r.prefix(16))… is a classic X25519 key, which is not quantum-safe; vaults take only "
                + "post-quantum age1pq1... keys: create a new key (sempere keys generate, or age-keygen -pq)"
        case .legacyVault(let classic):
            let old = classic.first ?? "OLD"
            let more = classic.count > 1 ? " (and the same for each other classic key: \(classic.dropFirst().joined(separator: ", ")))" : ""
            return "this vault uses a classic X25519 key, which is not quantum-safe, so its notes cannot be opened; "
                + "migrate first: sempere vault recipients replace \(old) NEW\(more), where NEW is a post-quantum "
                + "key (sempere keys generate)"
        case .classicIdentity:
            return "that is a classic X25519 key (AGE-SECRET-KEY-1...), and this vault takes only post-quantum keys: "
                + "use its AGE-SECRET-KEY-PQ-1... key, or create a new key (sempere keys generate, or "
                + "age-keygen -pq) and have it added to the vault"
        case .duplicateRecipient(let r): return "recipient \(r) is listed twice"
        case .unknownRecipient(let r): return "recipient \(r) is not part of this vault"
        case .lastRecipient: return "cannot remove the only recipient: the vault would become unreadable"
        case .labelCountMismatch: return "give no labels, or one label per recipient"
        case .vaultSecretUndecryptable: return "none of the given keys can decrypt this vault"
        case .invalidVaultSecret: return "the vault secret in vault.json is malformed"
        case .locked: return "the vault is locked: no key was given"
        case .noIdentities: return "no key was given, so notes cannot be decrypted"
        case .rewrapIncomplete(let files):
            return "a recipient change is unfinished (\(files.count) file(s) not rewrapped)"
        case .invalidNoteId(let n): return "'\(n)' is not a note id (lowercase UUID)"
        case .seqInUse(let device, let seq): return "device \(device) already has a revision with sequence number \(seq)"
        case .seqOutOfRange(let seq): return "sequence number \(seq) is outside 1...\(RevisionName.maxSeq)"
        case .revision(let name, let inner): return "\(name): \(inner)"
        case .workFactorOutOfRange(let n): return "scrypt work factor \(n) is outside the allowed range 15...18"
        case .workFactorTooHigh: return "the key file needs more scrypt work than this reader allows"
        case .identityFileMissing(let n): return "no stored key file \(n)"
        case .wrongPassphrase: return "wrong passphrase for the stored key file"
        case .emptyPassphrase: return "the passphrase is empty"
        case .identityFileMalformed: return "the stored key file holds no AGE-SECRET-KEY identity"
        case .identityMismatch(let r): return "the stored key file does not belong to recipient \(r)"
        case .rewrapJournalUnreadable(let why): return "the rewrap journal cannot be read: \(why)"
        case .rewrapJournalKept(let why): return "the rewrap journal is kept: \(why)"
        case .interrupted: return "interrupted (test hook)"
        case .fileTooLarge(let path, let limit): return "\(path) is larger than the \(limit)-byte limit"
        case .io(let why): return why
        case .readOnly(let reasons):
            return "this vault is read-only for this version of Sempere: " + reasons.descriptions.joined(separator: "; ")
                + "; update Sempere to change it"
        case .untrustedRecipients(let p): return p.description
        case .recipientsNotRepairable(let why): return why
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
            return "the attachment's file name does not match its content under this vault's secret "
                + "(renamed, planted, or named under an old secret: see `sempere blobs repair`)"
        case .referenceMismatch: return "the attachment is not the content the note references"
        case .contentTooLarge(let limit): return "the attachment is larger than \(limit) bytes"
        case .sourceChanged: return "the source file changed while it was being stored"
        }
    }
}

extension RevisionReadError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .unreadable(let why): return "cannot read the file: \(why)"
        case .undecryptable(let why): return "cannot decrypt: \(why)"
        case .tagMismatch: return "tag mismatch: the file was altered, moved or written under another vault secret"
        case .tagMismatchJournalUnreadable(let why): return "tag mismatch (\(why))"
        case .corruptBody(let why): return "damaged body: \(why)"
        case .undecodable(let why): return "cannot decode the revision: \(why)"
        case .newer(let why): return "written by a newer version of Sempere (\(why)): update Sempere to read it"
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
        case .invalidSecret: return "the vault secret is not 32 bytes"
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

extension RecipientsProblem: CustomStringConvertible {
    /// One line naming what changed and the keys that are not verified
    /// (post-quantum keys abbreviated).
    public var description: String {
        let why: String
        switch reason {
        case .tagMismatch: why = "vault.json's device list was changed without the vault's key (its tag does not verify)"
        case .tagRemoved: why = "vault.json's device list lost its authentication tag (downgrade)"
        case .secretUnconfirmed: why = "the vault's secret changed in a way this device cannot confirm"
        case .recordUnreadable: why = "this device's trust record for the vault cannot be read, so the list cannot be checked "
            + "(check the list, then: sempere vault recipients confirm)"
        case .markersMismatch: why = "vault.json's format or features were changed without the vault's key (its markers tag "
            + "does not verify)"
        case .markersRemoved: why = "vault.json's format and features lost their authentication tag (downgrade)"
        case .markersRolledBack: why = "vault.json names an older format or fewer features than this device last verified "
            + "(an older vault.json put back)"
        }
        var parts = [why]
        if !unexpected.isEmpty {
            parts.append("unexpected recipient(s): " + unexpected.map(Self.abbreviate).joined(separator: ", "))
        }
        if !missing.isEmpty { parts.append("missing: " + missing.map(Self.abbreviate).joined(separator: ", ")) }
        parts.append(reason.isMarkers
            ? "nothing is written to the vault until its markers are repaired (sempere vault markers repair)"
            : "nothing is encrypted to this list until it is repaired (sempere vault recipients repair)")
        return parts.joined(separator: "; ")
    }

    /// `age1pq1abcdefgh…stuvwxyz` for long keys.
    public static func abbreviate(_ key: String) -> String {
        key.count > 80 ? "\(key.prefix(16))…\(key.suffix(8))" : key
    }
}
