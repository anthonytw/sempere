import Age
import Foundation

/// Errors from the vault directory layer.
public enum VaultError: Error, Hashable, Sendable {
    /// `create` needs a directory name ending in `.sempere` (format.md §1).
    case invalidVaultName(String)
    /// The path (a vault, a revision file, an identity file) already exists.
    case alreadyExists(String)
    /// No `vault.json` at the given location.
    case notAVault(String)
    /// `vault.json` does not parse or breaks a rule of format.md §2.
    case manifestCorrupt(String)
    /// `vault.json`'s `format` is not a format identifier (`sempere/<major>`,
    /// format.md §7.1), or the manifest of a later major cannot be decoded
    /// well enough to open it read-only (§7.2).
    case unsupportedFormat(String)
    /// A vault needs at least one recipient.
    case noRecipients
    /// Not a Bech32 `age1...` (X25519) or `age1pq1...` (MLKEM768-X25519) recipient.
    case invalidRecipient(String)
    /// A classic X25519 (`age1...`) key offered as a recipient. Vaults take
    /// only post-quantum `age1pq1...` recipients (format.md §3.1).
    case classicRecipient(String)
    /// Only classic X25519 identities were offered: such a key can never
    /// open a vault, which lists only post-quantum keys (format.md §3.1).
    case classicIdentity
    /// The recipient is already listed.
    case duplicateRecipient(String)
    /// The recipient is not listed.
    case unknownRecipient(String)
    /// Removing the only recipient would leave the vault unreadable.
    case lastRecipient
    /// `labels` must be empty or match `recipients` one to one.
    case labelCountMismatch
    /// None of the identities decrypts `vaultSecret`.
    case vaultSecretUndecryptable(String)
    /// `vaultSecret` decrypts but is not 32 bytes.
    case invalidVaultSecret
    /// The operation needs the vault secret; the vault was opened without
    /// identities (read-only, names only).
    case locked
    /// The operation reads note files, but the vault holds no identities
    /// (created write-only: it has the secret but cannot decrypt).
    case noIdentities
    /// A recipient change is still unfinished because these files (as
    /// `<noteId>/<file>`) could not be rewrapped; fix or remove them and call
    /// `resumeRewrap()` before starting another change.
    case rewrapIncomplete([String])
    /// Not a lowercase hyphenated UUID note directory name.
    case invalidNoteId(String)
    /// Another revision of this note already uses `(device, seq)`.
    case seqInUse(device: String, seq: Int)
    /// A revision's `seq` is outside 1...`RevisionName.maxSeq`, so readers
    /// would reject it.
    case seqOutOfRange(Int)
    /// A revision could not be read; `name` is its file name.
    case revision(name: String, RevisionReadError)
    /// Writers use scrypt work factors 15...18 (format.md §3.2).
    case workFactorOutOfRange(Int)
    /// The identity file's scrypt work factor exceeds the reader's cap.
    case workFactorTooHigh
    /// No `keys/<recipient>.key.age`.
    case identityFileMissing(String)
    /// The passphrase does not decrypt the identity file.
    case wrongPassphrase
    /// A key file is never written under an empty passphrase.
    case emptyPassphrase
    /// The identity file decrypts but holds no `AGE-SECRET-KEY-1...` line, or
    /// is not a single-scrypt-recipient age file.
    case identityFileMalformed
    /// The identity in the file does not match the recipient in its name.
    case identityMismatch(String)
    /// The recipient-change journal exists but cannot be read, or this
    /// device refuses it (format.md §3.3.1 "Accepting the journal").
    case rewrapJournalUnreadable(String)
    /// `discardRefusedJournal` keeps the journal: this device accepts it (an
    /// unfinished change: finish it) or cannot read it now.
    case rewrapJournalKept(String)
    /// Test hook: a rewrap stopped after the requested number of files.
    case interrupted
    /// A file to read holds more than `limit` bytes (`BoundedRead`).
    case fileTooLarge(String, limit: Int)
    /// A filesystem operation failed.
    case io(String)
    /// The vault holds newer content (format.md §7.2): a later `format`,
    /// unknown `features`, or newer revisions this vault value has read. It
    /// may be read but never written (§7.3).
    case readOnly(ReadOnlyReasons)
    /// `vault.json`'s recipients list does not check (format.md §2.1): its
    /// tag does not verify, was removed, or the secret changed in a way this
    /// device cannot confirm. Nothing is encrypted to it; reading still works.
    /// `Vault.repairRecipients` rewrites the last verified list.
    case untrustedRecipients(RecipientsProblem)
    /// `repairRecipients` or `confirmRecipients` on a list that checks, or a
    /// repair that has no last verified list to write (pass `keeping:`).
    case recipientsNotRepairable(String)
    /// The vault folder is a partial copy (format.md §1.2): the operation
    /// must see every file of the vault. The value is the vault's path.
    case partialCopy(String)
    /// A note of a partial copy has not received all its revisions
    /// (format.md §1.2): nothing is written to it, or deleted from it, until
    /// they arrive. The value is the note id.
    case noteIncomplete(String)
}

/// Why one revision file could not be read, by stage. (Vault-level
/// preconditions, such as a locked vault, are `VaultError`s.)
public enum RevisionReadError: Error, Hashable, Sendable {
    /// The file could not be read from disk.
    case unreadable(String)
    /// age decryption failed (no matching identity, bad header, corrupt payload).
    case undecryptable(String)
    /// The inner HMAC tag does not match (format.md §4): tampered, replayed
    /// under another note or name, or written under another vault secret.
    case tagMismatch
    /// The tag does not match the current secret while a recipient change
    /// is pending whose journal (holding the outgoing secret) could not be
    /// read; the detail says why. The file may be fine once the journal is.
    case tagMismatchJournalUnreadable(String)
    /// The plaintext is not a valid framed gzip body.
    case corruptBody(String)
    /// The JSON does not decode as a revision, or names another note or file.
    case undecodable(String)
    /// Written by a newer version and not readable by this one (format.md
    /// §7.2, §7.4): a later body version, or a newer revision whose envelope
    /// or state does not decode. The vault is read-only once it is seen.
    case newer(String)
}

/// A vault directory (`*.sempere`, format.md §1) opened with zero or more
/// age identities.
///
/// Opened with identities that decrypt `vaultSecret`, the vault can read,
/// verify and write revisions and change recipients. Opened without
/// identities it is locked: it lists notes, revision names and identity
/// files only.
public struct Vault: Sendable {
    /// The `.sempere` directory.
    public let url: URL
    /// The manifest as last read or written.
    public internal(set) var manifest: VaultManifest
    let identities: [any AgeIdentity]
    /// The vault secret; nil when locked.
    internal(set) var secret: VaultSecret?
    /// During an unfinished secret-rotating rewrap: the secret files not yet
    /// rewrapped are still tagged with.
    internal(set) var previousSecret: VaultSecret?
    /// Why a pending rewrap journal could not be read when the vault was
    /// opened (nil when there is none, it read fine, or the vault is locked).
    public internal(set) var journalProblem: String?
    /// True when a pending rewrap journal was read and refused (format.md
    /// §3.3.1: planted, put back after its change finished, or not a journal):
    /// it gives no secret, and `discardRefusedJournal` may delete it. False
    /// when there is none, it is accepted, or it could not be read.
    public internal(set) var journalRefused = false
    /// Secrets this vault used before its current one, from this device's
    /// secret keyring (design §6.3, `SecretKeyring`): set only by
    /// `withOlderSecrets`, for the rewrap of this device's late files
    /// (`rewrapLateFiles`) and the checks of copies received during a key
    /// change (`classifyCopy`). Ordinary reads never use them.
    var olderSecrets: [VaultSecret] = []
    /// While `rewrapLateFiles` runs: the devices whose files under a keyring secret it rewraps (the
    /// files this device wrote, by the device id in their names); nil: every file (a recipient change's
    /// own rewrap, which uses the journal's secret, not the keyring's).
    var lateOwnDevices: Set<DeviceID>?
    /// The notes whose newer revisions this vault (or a copy) has read
    /// (format.md §7.3); shared by every copy.
    let readOnlyLatch = ReadOnlyLatch()
    /// Revision files decrypted by this vault (and its copies): what tests
    /// count to check that a path does not read a note twice.
    let revisionDecrypts = WorkCounter()
    /// Revision plaintext `loadForCompaction` holds between its decodes, and its peak (tests).
    let plainHeld = ByteGauge()
    /// How `vault.json`'s recipients checked when the vault was unlocked or
    /// last changed (format.md §2.1); `.notChecked` while locked.
    public internal(set) var recipientsStatus: RecipientsStatus = .notChecked
    /// Where this device keeps its trust record (format.md §2.1); nil keeps
    /// none (tests): every secret is then a first use.
    var trustStore: (any RecipientsTrustStore)?
    /// The trust record this value (and its copies) last saved, so writes do
    /// not read the store each time.
    let trustMemo = TrustMemo()

    // `package`: SempereWebDAV walks the same layout.
    package static let manifestName = "vault.json"
    package static let keysName = "keys"
    package static let notesName = "notes"
    /// Recipient-change journal (docs/io.md). An unknown file to other readers.
    package static let journalName = "rewrap-journal.json"

    var manifestURL: URL { url.appendingPathComponent(Self.manifestName) }
    var keysURL: URL { url.appendingPathComponent(Self.keysName) }
    var notesURL: URL { url.appendingPathComponent(Self.notesName) }
    var journalURL: URL { url.appendingPathComponent(Self.journalName) }

    /// The recipients every file is encrypted to.
    public var recipients: [VaultManifest.Recipient] { manifest.recipients }
    /// `vaultId` from the manifest.
    public var vaultId: UUID { manifest.vaultId }
    /// True when opened without identities: no vault secret, names only.
    public var isLocked: Bool { secret == nil }
    /// True when note files can be decrypted and verified: the vault secret
    /// is known and at least one identity is held. A vault created with
    /// `identities: []` is unlocked (it can write) but cannot read.
    public var canRead: Bool { secret != nil && !identities.isEmpty }
    /// The recipients (`age1...`) of the identities the vault was opened
    /// with, for a caller that must not remove the key it unlocked with.
    public var identityRecipients: Set<String> {
        Set(identities.compactMap { ($0 as? NativeIdentity)?.recipient.string })
    }

    /// Why this vault is read-only (format.md §7.3): its manifest's newer
    /// `format` or unknown `features`, and the notes whose newer revisions
    /// this vault value (or any copy of it) has read so far. Empty when
    /// writable.
    public var readOnlyReasons: ReadOnlyReasons {
        Self.readOnlyReasons(manifest, newerNotes: readOnlyLatch.newerNotes)
    }

    /// True when the vault must not be written (`readOnlyReasons` not empty).
    public var isReadOnly: Bool { !readOnlyReasons.isEmpty }

    static func readOnlyReasons(_ manifest: VaultManifest, newerNotes: [UUID] = []) -> ReadOnlyReasons {
        ReadOnlyReasons(vaultFormat: SempereFormat.isNewer(manifest.format) ? manifest.format : nil,
                        unknownFeatures: manifest.unknownFeatures, newerNotes: newerNotes)
    }

    /// Throws `VaultError.readOnly` when the vault holds newer content
    /// (format.md §7.2, §7.3): such a vault may be read but never written,
    /// not even to tag its recipients list.
    public func requireNotReadOnly() throws {
        let reasons = readOnlyReasons
        if !reasons.isEmpty { throw VaultError.readOnly(reasons) }
    }

    /// Every write calls it. Throws `VaultError.readOnly` for a vault holding
    /// newer content (format.md §7.3), checked first so that nothing below
    /// writes to such a vault, then `VaultError.untrustedRecipients` when the
    /// recipients list did not check (format.md §2.1): nothing is encrypted
    /// to it.
    public func requireWritable() throws {
        try requireNotReadOnly()
        try requireTrustedRecipients()
        if case .verified = recipientsStatus {
            try rememberRecipients()   // a writer keeps a trust record (format.md §2.1)
        }
    }

    /// Records that `note` holds newer content (format.md §7.3): from now on
    /// every write through this vault, or any copy of it, is refused.
    func noteNewerContent(in note: UUID) { readOnlyLatch.record(note) }

    /// Throws `VaultError.untrustedRecipients` when `recipientsStatus` is
    /// tampered (format.md §2.1). Callers that encrypt to the recipients
    /// outside `requireWritable` (capture profiles) call it.
    public func requireTrustedRecipients() throws {
        if let problem = recipientsStatus.problem { throw VaultError.untrustedRecipients(problem) }
    }

    /// Test seam (internal): a blob rename stops (`VaultError.interrupted`)
    /// after the new name is in place and before the old one is deleted,
    /// as a crash there would. Never set outside tests.
    var crashAfterBlobPlace = false

    /// True when a recipient change was interrupted; `resumeRewrap()` (or
    /// repeating the same `addRecipient`/`removeRecipient`) finishes it.
    public var pendingRewrap: Bool { FileIO.exists(journalURL) }

    // MARK: - Create and open

    /// Creates a vault: `vault.json` with a fresh `vaultId` and a fresh
    /// 32-byte vault secret encrypted (armored) to `recipients`, plus empty
    /// `keys/` and `notes/`.
    ///
    /// - Parameters:
    ///   - url: a directory whose name ends in `.sempere`; it may exist but
    ///     must not hold a `vault.json`.
    ///   - recipients: post-quantum (`age1pq1...`) only; an X25519 one throws
    ///     `classicRecipient` (format.md §3.1).
    ///   - labels: empty, or one label per recipient (stored as
    ///     `VaultManifest.Recipient.cleanLabel` makes them, as are the labels
    ///     of `addRecipient` and `replaceRecipient`).
    ///   - identities: kept for reading; may be empty (write-only use).
    ///   - vaultId, created: fixed values for reproducible fixtures.
    ///   - trust: this device's trust records (format.md §2.1); the new
    ///     vault's is saved there.
    ///   - label: the vault's display name (format.md §2 `label`), cleaned; nil or empty: none.
    public static func create(at url: URL, recipients: [NativeRecipient], labels: [String] = [],
                              identities: [any AgeIdentity] = [], vaultId: UUID = UUID(),
                              created: Date = Date(), trust: (any RecipientsTrustStore)? = nil,
                              label: String? = nil) throws -> Vault {
        try requirePostQuantum(recipients)
        guard url.lastPathComponent.hasSuffix(".sempere"), url.lastPathComponent.count > ".sempere".count else {
            throw VaultError.invalidVaultName(url.lastPathComponent)
        }
        guard !recipients.isEmpty else { throw VaultError.noRecipients }
        guard labels.isEmpty || labels.count == recipients.count else { throw VaultError.labelCountMismatch }
        let keys = recipients.map(\.string)
        if let dup = firstDuplicate(keys) { throw VaultError.duplicateRecipient(dup) }
        let manifestURL = url.appendingPathComponent(manifestName)
        guard !FileIO.exists(manifestURL) else { throw VaultError.alreadyExists(manifestURL.path) }

        let secret = VaultSecret.random()
        let entries = keys.enumerated().map { i, k in
            VaultManifest.Recipient(key: k, label: labels.isEmpty ? "" : VaultManifest.Recipient.cleanLabel(labels[i]),
                                    added: created)
        }
        let manifest = VaultManifest(vaultId: vaultId, created: created, recipients: entries,
                                     vaultSecret: try encryptSecret(secret, to: recipients),
                                     recipientsTag: RecipientsAuth.tag(vaultId: vaultId, keys: keys, secret: secret),
                                     label: VaultManifest.cleanVaultLabel(label))
        try FileIO.createDirectory(url)
        try FileIO.createDirectory(url.appendingPathComponent(keysName))
        try FileIO.createDirectory(url.appendingPathComponent(notesName))
        let written = try writeManifest(manifest, to: manifestURL, replacing: false, secret: secret)
        var vault = Vault(url: url, manifest: written, identities: identities, secret: secret, previousSecret: nil,
                          journalProblem: nil, recipientsStatus: .verified(.firstUse), trustStore: trust)
        try? vault.rememberRecipients()   // else saved by the first write (requireWritable)
        return vault
    }

    /// Opens a vault. With identities, decrypts the vault secret using the
    /// first that matches; with none, opens locked (names only).
    ///
    /// - Throws: `notAVault`, `manifestCorrupt` (also for a classic X25519
    ///   recipient, format.md §3.1), `unsupportedFormat`,
    ///   `vaultSecretUndecryptable`, `invalidVaultSecret`; `classicIdentity`
    ///   when only X25519 identities are given.
    ///
    /// With identities, the recipients list is checked (format.md §2.1,
    /// `recipientsStatus`) against this device's trust record in `trust`,
    /// which a verified list updates. A tampered list does not stop the open:
    /// reading works, writing throws `VaultError.untrustedRecipients`.
    public static func open(at url: URL, identities: [any AgeIdentity] = [],
                            trust: (any RecipientsTrustStore)? = nil) throws -> Vault {
        let manifestURL = url.appendingPathComponent(manifestName)
        guard FileIO.exists(manifestURL) else { throw VaultError.notAVault(url.path) }
        let manifestBytes = readsWithoutLinks(url)
            ? try BoundedRead.contents(under: url, manifestName, maxBytes: BoundedRead.maxManifestBytes)
            : try FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes)
        let manifest = try readManifest(manifestBytes)
        var vault = Vault(url: url, manifest: manifest, identities: identities, secret: nil, previousSecret: nil,
                          journalProblem: nil, trustStore: trust)
        guard !identities.isEmpty else { return vault }
        do { vault.secret = try decryptSecret(manifest.vaultSecret, with: identities) } catch {
            // A classic key, which never opens a vault: say so, rather than
            // only "no key matches".
            if identities.allSatisfy(Self.isClassic) { throw VaultError.classicIdentity }
            throw error
        }
        if let secret = vault.secret {
            vault.recipientsStatus = Self.recipientsStatus(manifest, secret: secret, trust: trust)
        }
        if vault.pendingRewrap {
            // Recorded, not thrown: the vault stays usable, verify() and
            // tag mismatches surface it, and resumeRewrap() throws it.
            switch vault.judgeJournal() {
            case .accepted(_, let previous): vault.previousSecret = previous
            case .refused(let why):
                vault.journalProblem = "\(VaultError.rewrapJournalUnreadable(why))"
                vault.journalRefused = true
            case .unreadable(let why): vault.journalProblem = "\(VaultError.rewrapJournalUnreadable(why))"
            }
        }
        // A device that keeps a record remembers that nothing is pending
        // (format.md §3.3.1 "Finished rotations").
        vault.noteRewrapSettled()
        return vault
    }

    /// `RecipientsAuth.evaluate` against this device's record in `trust`.
    /// A record that exists but cannot be read fails closed: a list that
    /// would otherwise be writable is `tampered(.recordUnreadable)` (security
    /// review 2026-10, R5); one that does not check stays as it is.
    static func recipientsStatus(_ manifest: VaultManifest, secret: VaultSecret,
                                 trust: (any RecipientsTrustStore)?) -> RecipientsStatus {
        let record: RecipientsTrustRecord?
        do { record = try trust?.record(for: manifest.vaultId) } catch {
            let status = RecipientsAuth.evaluate(manifest, secret: secret, record: nil)
            guard status.allowsWriting else { return status }
            return .tampered(.init(reason: .recordUnreadable, current: manifest.recipients.map(\.key),
                                   restore: nil, record: nil))
        }
        return RecipientsAuth.evaluate(manifest, secret: secret, record: record)
    }

    /// Parses and validates manifest bytes (format, recipients).
    static func readManifest(_ data: Data) throws -> VaultManifest {
        let manifest: VaultManifest
        do { manifest = try VaultManifest.decode(data) } catch {
            // A later major that does not decode cannot be opened even read-only (format.md §7.2).
            if let format = VaultManifest.peekFormat(data), SempereFormat.isNewer(format) {
                throw VaultError.unsupportedFormat(format)
            }
            throw VaultError.manifestCorrupt("\(error)")
        }
        guard let major = SempereFormat.major(of: manifest.format) else {
            throw VaultError.unsupportedFormat(manifest.format)
        }
        guard !manifest.recipients.isEmpty else { throw VaultError.manifestCorrupt("no recipients") }
        // A later major may list recipient types this version does not know;
        // it is opened read-only (format.md §7.3) with whatever key matches.
        // Up to this major every recipient is post-quantum (format.md §3.1): a
        // classic X25519 key in the list is a damaged or tampered vault.json,
        // and nothing is ever read or encrypted under it.
        for r in manifest.recipients where major <= SempereFormat.major {
            guard let recipient = try? NativeRecipient(string: r.key) else {
                throw VaultError.manifestCorrupt("invalid recipient \(r.key)")
            }
            guard recipient.isPostQuantum else {
                throw VaultError.manifestCorrupt("classic X25519 recipient \(r.key.prefix(16))…: "
                    + "vaults list only post-quantum age1pq1... keys")
            }
        }
        if let dup = firstDuplicate(manifest.recipients.map(\.key)) {
            throw VaultError.manifestCorrupt("duplicate recipient \(dup)")
        }
        return manifest
    }

    /// Writes the manifest atomically and returns it as it will read back
    /// (dates at millisecond precision). Its version markers are tagged under
    /// `secret` (format.md §2.1 "Version markers"): every write of `vault.json`
    /// by this implementation carries `markersTag` for what it writes.
    static func writeManifest(_ m: VaultManifest, to url: URL, replacing: Bool, secret: VaultSecret) throws -> VaultManifest {
        var m = m
        m.tagMarkers(secret: secret)
        let data = try m.encoded()
        try FileIO.writeAtomically(data, to: url, replacing: replacing)
        return try VaultManifest.decode(data)
    }

    static func encryptSecret(_ secret: VaultSecret, to recipients: [NativeRecipient]) throws -> String {
        String(decoding: try encrypt(secret.bytes, to: recipients, armor: true), as: UTF8.self)
    }

    /// Every vault write encrypts with this: to post-quantum recipients only
    /// (format.md §3.1); a classic one throws `classicRecipient`.
    static func encrypt(_ data: Data, to recipients: [NativeRecipient], armor: Bool = false) throws -> Data {
        try requirePostQuantum(recipients)
        return try AgeFile.encrypt(data, to: recipients, armor: armor)
    }

    /// Throws `classicRecipient` for the first classic X25519 key in
    /// `recipients`: nothing of a vault is ever encrypted to one.
    static func requirePostQuantum(_ recipients: [NativeRecipient]) throws {
        if let classic = recipients.first(where: { !$0.isPostQuantum }) {
            throw VaultError.classicRecipient(classic.string)
        }
    }

    static func decryptSecret(_ armored: String, with identities: [any AgeIdentity]) throws -> VaultSecret {
        let plain: Data
        do { plain = try AgeFile.decrypt(Data(armored.utf8), with: identities) } catch {
            throw VaultError.vaultSecretUndecryptable("\(error)")
        }
        guard let s = try? VaultSecret(bytes: plain) else { throw VaultError.invalidVaultSecret }
        return s
    }

    /// An X25519 (not post-quantum) age identity.
    static func isClassic(_ identity: any AgeIdentity) -> Bool {
        if identity is X25519Identity { return true }
        if let native = identity as? NativeIdentity { return !native.isPostQuantum }
        return false
    }

    static func firstDuplicate(_ keys: [String]) -> String? {
        var seen = Set<String>()
        for k in keys where !seen.insert(k).inserted { return k }
        return nil
    }

    /// The manifest recipients as age recipients: post-quantum only (format.md
    /// §3.1), else `classicRecipient`.
    func ageRecipients() throws -> [NativeRecipient] {
        let recipients = try manifest.recipients.map { r in
            do { return try NativeRecipient(string: r.key) } catch { throw VaultError.invalidRecipient(r.key) }
        }
        try Self.requirePostQuantum(recipients)
        return recipients
    }

    func requireSecret() throws -> VaultSecret {
        guard let secret else { throw VaultError.locked }
        return secret
    }

    /// The secret, for operations that also decrypt note files.
    func requireReadable() throws -> VaultSecret {
        let secret = try requireSecret()
        guard !identities.isEmpty else { throw VaultError.noIdentities }
        return secret
    }

    // MARK: - Recipients (format.md §3.3)

    /// What a recipient change did to the files under `notes/`.
    public struct RewrapReport: Hashable, Sendable {
        /// Files re-encrypted in this run, as `<noteId>/<file>`.
        public var rewrapped: [String] = []
        /// Files already encrypted to the current set (and tagged with the
        /// current secret); left untouched.
        public var alreadyCurrent: [String] = []
        /// How attachment blobs were rewrapped (format.md §8.1.5); nil when
        /// no rewrap ran.
        public var blobMethod: RewrapMethod?
        /// Files left untouched because they could not be read or verified.
        /// While any remain the journal is kept (`pendingRewrap` stays true)
        /// and `resumeRewrap()` retries them.
        public var failures: [String: RevisionReadError] = [:]
        /// Inbox files (format.md §11) left as they are because they verify
        /// under neither the current nor the outgoing capture key, or this
        /// device cannot decrypt them: never adopted, so they do not keep
        /// the journal.
        public var inboxSkipped: [String] = []
        /// `settings.age` (format.md §13) when it was left as it is because it
        /// cannot be decrypted or verified here: it does not keep the journal,
        /// and the next settings write replaces it.
        public var settingsSkipped: [String] = []
        /// Notebook records (format.md §14) left as they are because they
        /// cannot be decrypted or verified here: they do not keep the journal.
        public var notebooksSkipped: [String] = []
        /// Why a rewrap journal this device refuses was moved aside when this
        /// change started (`discardRefusedJournal`); nil when there was none.
        public var discardedJournal: String?
        /// `rewrapLateFiles`: files under a keyring secret left as they are because another device wrote
        /// them (revisions), or no revision this device can read references them (blobs).
        public var lateSkipped: [String] = []

        public init() {}

        /// True when every file is encrypted to the current recipients.
        public var isComplete: Bool { failures.isEmpty }

        mutating func merge(_ o: RewrapReport) {
            rewrapped += o.rewrapped
            alreadyCurrent += o.alreadyCurrent
            blobMethod = o.blobMethod ?? blobMethod
            failures.merge(o.failures) { $1 }
            inboxSkipped += o.inboxSkipped
            settingsSkipped += o.settingsSkipped
            notebooksSkipped += o.notebooksSkipped
            lateSkipped += o.lateSkipped
            discardedJournal = o.discardedJournal ?? discardedJournal
        }
    }

    /// Adds a recipient: re-encrypts `vaultSecret` and then every revision
    /// to the new set (payload unchanged). Finishes an interrupted change
    /// first; repeating an interrupted `addRecipient` call completes it.
    /// A journal this device refuses is moved aside first (`discardedJournal`
    /// in the report), as for `removeRecipient` and `replaceRecipient`.
    ///
    /// - Throws: `classicRecipient` for an X25519 recipient (post-quantum
    ///   only, format.md §3.1).
    ///
    /// - Parameter policy: how attachment blobs are rewrapped (format.md
    ///   §8.1.5); by default an addition rewrites blob headers only.
    @discardableResult
    ///
    /// - Parameter keyChange: the mode and late-file window the journal records (format.md §3.3.1).
    public mutating func addRecipient(_ recipient: NativeRecipient, label: String,
                                      added: Date = Date(), policy: RewrapPolicy = RewrapPolicy(),
                                      keyChange: KeyChangePolicy = .routine) throws -> RewrapReport {
        guard recipient.isPostQuantum else { throw VaultError.classicRecipient(recipient.string) }
        return try addRecipient(recipient, label: label, added: added, policy: policy, stopAfter: nil, keyChange: keyChange)
    }

    /// Removes a recipient: rotates the vault secret, re-encrypts it to the
    /// remaining set, then re-encrypts and re-tags every revision (gzip bytes
    /// unchanged). Finishes an interrupted change first; repeating an
    /// interrupted `removeRecipient` call completes it.
    ///
    /// - Parameter policy: how attachment blobs are rewrapped (format.md
    ///   §8.1.5); by default a removal re-encrypts every blob under a new
    ///   file key and renames it under the new secret.
    @discardableResult
    public mutating func removeRecipient(_ recipient: NativeRecipient, policy: RewrapPolicy = RewrapPolicy(),
                                         keyChange: KeyChangePolicy = .routine) throws -> RewrapReport {
        try removeRecipient(recipient, policy: policy, stopAfter: nil, keyChange: keyChange)
    }

    /// Replaces `old` with `new` (keeping `old`'s label unless `label` is
    /// given) in one change (a key rotation): rotates the vault secret and
    /// rewraps every revision once. Finishes an interrupted change first;
    /// repeating an interrupted call completes it, but only with **both**
    /// identities: the new one opens `vault.json`, the old one the files not
    /// yet rewrapped. Keep the old key until no rewrap is pending.
    /// Blobs follow the removal row of `policy` (format.md §8.1.5).
    @discardableResult
    public mutating func replaceRecipient(_ old: NativeRecipient, with new: NativeRecipient, label: String? = nil,
                                          added: Date = Date(), policy: RewrapPolicy = RewrapPolicy(),
                                          keyChange: KeyChangePolicy = .routine) throws -> RewrapReport {
        guard new.isPostQuantum else { throw VaultError.classicRecipient(new.string) }
        return try replaceRecipient(old, with: new, label: label, added: added, policy: policy, stopAfter: nil,
                                    keyChange: keyChange)
    }

    /// Finishes an interrupted recipient change: rewraps every file not yet
    /// encrypted to the current recipients, then deletes the journal.
    @discardableResult
    public mutating func resumeRewrap() throws -> RewrapReport {
        try resumeRewrap(stopAfter: nil)
    }

    mutating func addRecipient(_ recipient: NativeRecipient, label: String, added: Date,
                               policy: RewrapPolicy = RewrapPolicy(), stopAfter: Int?,
                               keyChange: KeyChangePolicy = .routine) throws -> RewrapReport {
        _ = try requireSecret()
        try requireTrustedRecipients()
        let key = recipient.string
        var report = RewrapReport()
        report.discardedJournal = try discardJournalBlockingChange()
        let resumed = pendingRewrap
        if resumed {
            report = try resumeRewrap(stopAfter: stopAfter)
            guard report.isComplete else {
                // The earlier change is the one the caller repeated, or one
                // that must finish first; either way nothing new starts.
                if manifest.recipients.contains(where: { $0.key == key }) { return report }
                throw VaultError.rewrapIncomplete(report.failures.keys.sorted())
            }
        }
        if manifest.recipients.contains(where: { $0.key == key }) {
            guard resumed else { throw VaultError.duplicateRecipient(key) }
            return report
        }
        var next = manifest.recipients
        next.append(.init(key: key, label: VaultManifest.Recipient.cleanLabel(label), added: added))
        report.merge(try changeRecipients(next, rotate: false, policy: policy, stopAfter: stopAfter, keyChange: keyChange))
        return report
    }

    mutating func replaceRecipient(_ old: NativeRecipient, with new: NativeRecipient, label: String?, added: Date,
                                   policy: RewrapPolicy = RewrapPolicy(), stopAfter: Int?,
                                   keyChange: KeyChangePolicy = .routine) throws -> RewrapReport {
        _ = try requireSecret()
        try requireTrustedRecipients()
        let oldKey = old.string, newKey = new.string
        var report = RewrapReport()
        report.discardedJournal = try discardJournalBlockingChange()
        func has(_ k: String) -> Bool { manifest.recipients.contains { $0.key == k } }
        let resumed = pendingRewrap
        if resumed {
            report = try resumeRewrap(stopAfter: stopAfter)
            guard report.isComplete else {
                if has(newKey) && !has(oldKey) { return report }
                throw VaultError.rewrapIncomplete(report.failures.keys.sorted())
            }
        }
        if has(newKey) && !has(oldKey) && resumed { return report }
        guard let index = manifest.recipients.firstIndex(where: { $0.key == oldKey }) else {
            throw VaultError.unknownRecipient(oldKey)
        }
        guard !has(newKey) else { throw VaultError.duplicateRecipient(newKey) }
        var next = manifest.recipients
        next[index] = .init(key: newKey, label: label.map(VaultManifest.Recipient.cleanLabel) ?? next[index].label,
                            added: added)
        report.merge(try changeRecipients(next, rotate: true, policy: policy, stopAfter: stopAfter, keyChange: keyChange))
        return report
    }

    mutating func removeRecipient(_ recipient: NativeRecipient, policy: RewrapPolicy = RewrapPolicy(),
                                  stopAfter: Int?, keyChange: KeyChangePolicy = .routine) throws -> RewrapReport {
        _ = try requireSecret()
        try requireTrustedRecipients()
        let key = recipient.string
        var report = RewrapReport()
        report.discardedJournal = try discardJournalBlockingChange()
        let resumed = pendingRewrap
        if resumed {
            report = try resumeRewrap(stopAfter: stopAfter)
            guard report.isComplete else {
                if !manifest.recipients.contains(where: { $0.key == key }) { return report }
                throw VaultError.rewrapIncomplete(report.failures.keys.sorted())
            }
        }
        guard manifest.recipients.contains(where: { $0.key == key }) else {
            guard resumed else { throw VaultError.unknownRecipient(key) }
            return report
        }
        let next = manifest.recipients.filter { $0.key != key }
        guard !next.isEmpty else { throw VaultError.lastRecipient }
        report.merge(try changeRecipients(next, rotate: true, policy: policy, stopAfter: stopAfter, keyChange: keyChange))
        return report
    }

    /// A recipient change the user starts is not blocked by a journal this
    /// device refuses, whatever its age (format.md §3.3.1 "Refused journals";
    /// security review 2026-10, S19): it is moved aside first, as
    /// `discardRefusedJournal` does. Returns why; nil when there was none to
    /// take away (no journal, or one accepted or unreadable, which the change
    /// then handles or refuses as before).
    mutating func discardJournalBlockingChange() throws -> String? {
        guard pendingRewrap, case .refused = judgeJournal() else { return nil }
        return try discardRefusedJournal()
    }

    mutating func resumeRewrap(stopAfter: Int?) throws -> RewrapReport {
        _ = try requireReadable()
        try requireWritable()
        guard pendingRewrap else { return RewrapReport() }
        try requireCompleteCopy()
        let (journal, previous) = try readJournal()
        previousSecret = previous
        journalProblem = nil
        journalRefused = false
        // The method the change started with (format.md §3.3.1).
        let method: RewrapMethod = journal.rekeyBlobs ? .reencrypt : .headerOnly
        return try finishRewrap(blobs: method, stopAfter: stopAfter)
    }

    /// Rewraps, then removes the journal only if every file is complete.
    /// Otherwise the journal (and the outgoing secret in it) stays, so the
    /// files that failed can still be verified and rewrapped by a retry.
    mutating func finishRewrap(blobs: RewrapMethod, stopAfter: Int?, stopBeforeFinish: Bool = false) throws -> RewrapReport {
        let report = try rewrapNotes(blobs: blobs, stopAfter: stopAfter)
        guard report.isComplete else { return report }
        if stopBeforeFinish { throw VaultError.interrupted }
        // The binding goes first (format.md §3.3.1 step 4): a journal left by
        // a crash between the two is then refused, never accepted again.
        try clearRewrapPending()
        // Gone already when another device took it away meanwhile.
        if FileIO.exists(journalURL) { try FileIO.remove(journalURL) }
        previousSecret = nil
        journalProblem = nil
        journalRefused = false
        try? rememberRecipients()   // rewrapFinished (§3.3.1 "Finished rotations")
        return report
    }

    /// Journal first (holding the outgoing secret when rotating; durable
    /// before vault.json changes, since the atomic write fsyncs the
    /// directory), then the manifest, then the files, then the journal is
    /// removed if every file is complete. See format.md §3.3.1, docs/io.md.
    ///
    /// The new list is tagged (format.md §2.1) in the same write, with a
    /// `secretLink` when the secret rotates. `repairing` skips the check of
    /// the current list: a repair writes the last verified one instead.
    mutating func changeRecipients(_ next: [VaultManifest.Recipient], rotate: Bool, policy: RewrapPolicy,
                                   stopAfter: Int?, repairing: Bool = false,
                                   keyChange: KeyChangePolicy = .routine) throws -> RewrapReport {
        let prepared = try prepareChange(next, rotate: rotate, policy: policy, repairing: repairing, keyChange: keyChange)
        var faults = RewrapFaults.none
        if let stopAfter { faults.stop = .afterFiles(stopAfter) }
        return try commitChange(prepared, faults: faults, keyring: nil, now: Date())
    }

    /// Everything of a recipient change before its first write (format.md
    /// §3.3.1 step 1's journal bytes included): the checks, the new list and
    /// the journal, so that a caller can claim every sync target with exactly
    /// those bytes before anything changes locally (design §6.1 C1).
    func prepareChange(_ next: [VaultManifest.Recipient], rotate: Bool, policy: RewrapPolicy, repairing: Bool,
                       keyChange: KeyChangePolicy, now: Date = Date()) throws -> PreparedKeyChange {
        let current = try requireReadable()
        // A repair skips the check of the current list, never the read-only rule (format.md §7.3).
        if repairing { try requireNotReadOnly() } else { try requireWritable() }
        // A rewrap must see every file: one a partial copy lacks would stay under the old keys (format.md §1.2).
        try requireCompleteCopy()
        // A newer vault.json synced in since open makes the vault read-only
        // (format.md §7.3): refuse before the journal is written.
        var onDisk = (try? Self.readManifest(FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))) ?? manifest
        let reasons = Self.readOnlyReasons(onDisk)
        if !reasons.isEmpty { throw VaultError.readOnly(reasons) }
        // `next` was built from this value's list, and a repair judged it: a
        // list or secret changed on disk since open (another device's change)
        // would be overwritten, dropping a key that device added.
        guard onDisk.recipients.map(\.key) == manifest.recipients.map(\.key), onDisk.vaultSecret == manifest.vaultSecret else {
            throw VaultError.manifestCorrupt(VaultError.changedSinceOpened)
        }
        // Markers changed on disk since open are not re-tagged under the new secret (N3).
        // A repair restores them instead: the larger of those on disk and this
        // device's record, as `repairMarkers` would (an attacker who changed the
        // list may have changed them too, and neither repair could run first).
        if repairing {
            onDisk = try Self.restoringMarkers(onDisk, recorded: recordedMarkers)
        } else if !onDisk.markersIntact(secret: current) {
            throw VaultError.manifestCorrupt(VaultError.markersChangedSinceOpened)
        }
        let ageNext = try next.map { r in
            do { return try NativeRecipient(string: r.key) } catch { throw VaultError.invalidRecipient(r.key) }
        }
        try Self.requirePostQuantum(ageNext)
        let method = policy.method(rotating: rotate)
        let journal = RewrapJournal(format: SempereFormat.identifier,
                                    previousVaultSecret: rotate ? try Self.encryptSecret(current, to: ageNext) : nil,
                                    rekeyBlobs: method == .reencrypt,
                                    mode: keyChange.mode.rawValue,
                                    lateFileWindowDays: keyChange.lateFileWindowDays,
                                    changedAt: RFC3339.string(from: now))
        return PreparedKeyChange(vaultId: vaultId, base: onDisk, next: next, rotate: rotate, method: method,
                                 journal: try InkJSON.encoder().encode(journal), keyChange: keyChange,
                                 changedAt: RFC3339.parse(journal.changedAt ?? "") ?? now)
    }

    /// Steps K1 to K4 of design §6.1 (format.md §3.3.1 steps 1 to 4) for a
    /// prepared change: the journal (exactly the prepared bytes), then
    /// `vault.json` binding it, then every file, then the journal goes.
    /// With `keyring`, the outgoing secret is stored in it, with the change's
    /// policy, before anything is written (design §6.3). `faults` stops the
    /// change where a crash would (tests, `RewrapFaults`).
    mutating func commitChange(_ p: PreparedKeyChange, faults: RewrapFaults, keyring: (any SecretKeyringStore)?,
                               now: Date, manifestWritten: ((Data) throws -> Void)? = nil) throws -> RewrapReport {
        let current = try requireReadable()
        guard p.vaultId == vaultId else { throw VaultError.manifestCorrupt("the prepared change is for another vault") }
        // Nothing may have changed since it was prepared (another device's change synced in):
        // the prepared list was built from that vault.json.
        let onDisk = try Self.readManifest(FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))
        guard onDisk.recipients.map(\.key) == p.base.recipients.map(\.key), onDisk.vaultSecret == p.base.vaultSecret,
              onDisk.recipients.map(\.key) == manifest.recipients.map(\.key), onDisk.vaultSecret == manifest.vaultSecret else {
            throw VaultError.manifestCorrupt(VaultError.changedSinceOpened)
        }
        let ageNext = try p.next.map { r in
            do { return try NativeRecipient(string: r.key) } catch { throw VaultError.invalidRecipient(r.key) }
        }
        let newSecret = p.rotate ? VaultSecret.random() : current
        // Signed before anything is written (it throws where ML-DSA is
        // unavailable); a change that keeps the secret keeps a signed link
        // and drops a malformed one.
        let link: SecretLink?
        if p.rotate {
            link = try RecipientsAuth.link(from: current, to: newSecret, vaultId: p.base.vaultId)
        } else if case .signed? = p.base.secretLink {
            link = p.base.secretLink
        } else {
            link = nil
        }
        // The keyring holds the outgoing secret before vault.json stops naming it (design §6.3, C0).
        if let keyring {
            try keyring.update(vaultId: vaultId) { ring in
                ring.remember(current, now: now)
                if p.rotate {
                    ring.noteReplaced(current, now: now)
                    ring.notePolicy(p.keyChange, outgoing: current, changedAt: p.changedAt)
                }
            }
        }
        try FileIO.writeAtomically(p.journal, to: journalURL, replacing: true)
        previousSecret = p.rotate ? current : nil
        if faults.stop == .afterJournal { throw VaultError.interrupted }

        var m = p.base
        m.recipients = p.next
        m.vaultSecret = try Self.encryptSecret(newSecret, to: ageNext)
        m.recipientsTag = RecipientsAuth.tag(vaultId: m.vaultId, keys: p.next.map(\.key), secret: newSecret)
        m.secretLink = link
        // The journal is bound to this vault.json under the new secret, which a
        // removed device does not hold (format.md §3.3.1 "Binding the journal"):
        // no journal counts without it.
        m.rewrapPending = RecipientsAuth.rewrapPending(vaultId: m.vaultId, journal: p.journal, secret: newSecret)
        manifest = try Self.writeManifest(m, to: manifestURL, replacing: true, secret: newSecret)
        secret = newSecret
        recipientsStatus = .verified(.unchanged)
        try? rememberRecipients()   // else saved by the next write (requireWritable)
        if let keyring { try? keyring.update(vaultId: vaultId) { $0.remember(newSecret, now: now) } }
        try manifestWritten?(try FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))
        if faults.stop == .afterManifest { throw VaultError.interrupted }

        return try finishRewrap(blobs: p.method, stopAfter: faults.stopAfterFiles, stopBeforeFinish: faults.stop == .beforeFinish)
    }

    // MARK: - Authenticated recipients (format.md §2.1)

    /// Saves this device's trust record for the current (verified) list.
    /// Writers keep one (format.md §2.1), so a record that cannot be read
    /// or saved is an error, and it is tried again by the next write (only a
    /// saved record is memoized; security review 2026-10, R5).
    /// With `replacing`, the record is saved without reading the old one
    /// (the user confirmed the list: an unreadable record is replaced).
    ///
    /// The record keeps the version markers last verified (`markers`, else
    /// those of `manifest`, format.md §2.1 "Version markers"), never fewer
    /// than it held: they only grow.
    func rememberRecipients(replacing: Bool = false, markers: VaultMarkers? = nil) throws {
        guard let trustStore, let secret else { return }
        var record = try RecipientsTrustRecord(vaultId: vaultId, secret: secret, recipients: manifest.recipients.map(\.key),
                                               markers: markers ?? VaultMarkers(manifest), rewrapFinished: rewrapSettled)
        if let memo = trustMemo.last, memo.vaultId == vaultId {
            record.markers = record.markers.merged(with: memo.markers)
            // `rewrapFinished` never goes back while the secret stays (format.md §3.3.1).
            if memo.linkPublicKeys == record.linkPublicKeys, memo.rewrapFinished { record.rewrapFinished = true }
        }
        guard replacing || trustMemo.last != record else { return }
        let stored = replacing ? nil : try trustStore.record(for: vaultId)
        if let seen = stored?.markers { record.markers = record.markers.merged(with: seen) }
        if let stored, stored.linkPublicKeys == record.linkPublicKeys, stored.rewrapFinished { record.rewrapFinished = true }
        if replacing || stored != record { try trustStore.save(record) }
        trustMemo.last = record
    }

    /// Repairs a tampered list (format.md §2.1 "Repair"): writes the last
    /// verified list (`keeping`, else the problem's `restore`), keeping the
    /// labels the current entries have, as a recipient removal: the secret
    /// rotates and every file is rewrapped, so no file stays encrypted to an
    /// unexpected key.
    ///
    /// - Parameter keeping: the keys to keep, in order; each must be listed
    ///   now or be in this device's trust record (a key the attacker deleted
    ///   comes back with an empty label). Needed when this device cannot tell
    ///   the last verified list.
    /// - Throws: `recipientsNotRepairable` when the list checks, when no list
    ///   is known or given, after an unconfirmed secret change (the files are
    ///   tagged under a secret this device no longer holds: restore
    ///   `vault.json` from a backup or another device, or confirm the list), or
    ///   while a recipient change is unfinished (its journal holds a secret a
    ///   second rotation would lose: restore `vault.json` from a backup).
    @discardableResult
    public mutating func repairRecipients(keeping: [String]? = nil, policy: RewrapPolicy = RewrapPolicy(),
                                          keyChange: KeyChangePolicy = .routine) throws -> RewrapReport {
        _ = try requireReadable()
        guard let problem = recipientsStatus.problem else {
            throw VaultError.recipientsNotRepairable("the recipients list checks; nothing to repair")
        }
        guard problem.reason != .secretUnconfirmed else {
            throw VaultError.recipientsNotRepairable("the vault's secret was replaced: restore vault.json from a backup or "
                + "another device, or confirm the list if the change was yours")
        }
        guard let keys = keeping ?? problem.restore, !keys.isEmpty else {
            throw VaultError.recipientsNotRepairable("this device does not know the last verified list: name the keys to keep")
        }
        guard !pendingRewrap else {
            throw VaultError.recipientsNotRepairable(journalRefused ? pendingRewrapAdvice
                : "a recipient change is unfinished; restore vault.json from a backup")
        }
        if let dup = Self.firstDuplicate(keys) { throw VaultError.duplicateRecipient(dup) }
        let remembered = Set((try? trustStore?.record(for: vaultId))??.recipients ?? [])
        var next: [VaultManifest.Recipient] = []
        for k in keys {
            if let entry = manifest.recipients.first(where: { $0.key == k }) {
                next.append(entry)
            } else if remembered.contains(k), (try? NativeRecipient(string: k)) != nil {
                next.append(.init(key: k, label: "", added: Date()))
            } else {
                throw VaultError.unknownRecipient(k)
            }
        }
        return try changeRecipients(next, rotate: true, policy: policy, stopAfter: nil, repairing: true, keyChange: keyChange)
    }

    /// Confirms the current list on this device after the user checked it
    /// (format.md §2.1): a device that missed a legitimate change
    /// (`secretUnconfirmed`), or whose trust record is unreadable
    /// (`recordUnreadable`). Only a list whose tag is present and verifies
    /// under the current secret is confirmed; nothing in the vault's list
    /// changes. Updates the trust record.
    public mutating func confirmRecipients() throws {
        guard let problem = recipientsStatus.problem else {
            throw VaultError.recipientsNotRepairable("the recipients list checks; nothing to confirm")
        }
        guard problem.reason != .tagMismatch else {
            throw VaultError.recipientsNotRepairable("the tag does not verify: repair the list instead")
        }
        guard problem.reason != .tagRemoved else {
            throw VaultError.recipientsNotRepairable("the list's tag was removed: repair the list instead")
        }
        // Version markers changed without the key are never confirmed away:
        // only `repairMarkers` restores them (format.md §2.1 "Version markers").
        guard !problem.reason.isMarkers else {
            throw VaultError.recipientsNotRepairable("the vault's format or features were changed without its key: "
                + "repair them instead (sempere vault markers repair)")
        }
        // Only a list this device can check is confirmed: tagged under the
        // secret it holds, never a tag stripped or bogus (security review
        // 2026-10, R3, R5).
        guard let tag = manifest.recipientsTag,
              RecipientsAuth.verifyTag(tag, vaultId: vaultId, keys: manifest.recipients.map(\.key), secret: try requireSecret())
        else {
            throw VaultError.recipientsNotRepairable(problem.reason == .secretUnconfirmed
                ? "the vault's secret was replaced and its list carries no tag that verifies: restore vault.json "
                    + "from a backup or another device"
                : "the tag does not verify: repair the list instead")
        }
        // Nor does confirming the list accept markers that do not check: the
        // list's problems are decided before the markers are looked at (N3).
        // They are restored instead, as a repair would: the larger of those on
        // disk and this device's record, tagged (markers only grow, so this
        // never lowers them).
        let secret = try requireSecret()
        let recorded = (try? trustStore?.record(for: vaultId)) ?? nil
        if RecipientsAuth.markersProblem(manifest, secret: secret, record: recorded) != nil {
            let m = try Self.readManifest(FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))
            guard m.recipients.map(\.key) == manifest.recipients.map(\.key), m.vaultSecret == manifest.vaultSecret else {
                throw VaultError.manifestCorrupt(VaultError.changedSinceOpened)
            }
            try requireNotReadOnly()
            manifest = try Self.writeManifest(try Self.restoringMarkers(m, recorded: recorded?.markers), to: manifestURL,
                                              replacing: true, secret: secret)
        }
        recipientsStatus = .verified(.unchanged)
        try rememberRecipients(replacing: true)   // also over an unreadable record (R5)
    }

    struct RewrapJournal: Codable {
        var format: String
        /// Armored age file holding the secret that files not yet rewrapped
        /// are tagged with; absent when the change did not rotate the secret.
        var previousVaultSecret: String?
        /// How blobs are rewrapped (format.md §3.3.1, §8.1.5): true
        /// re-encrypts each under a new file key, false rewrites only its
        /// header. Required: a journal without it is unreadable.
        var rekeyBlobs: Bool
        /// The key-change mode (format.md §3.3.1, design §6.5): `routine` or
        /// `compromised`; absent means `routine`.
        var mode: String?
        /// The late-file window in days (design §6.5); absent means 7
        /// (0 in `compromised` mode).
        var lateFileWindowDays: Int?
        /// When the change was made (RFC 3339, the writer's clock): every late-file window ends at
        /// most this long after it, whenever a device first sees the change. Absent: 0 days.
        var changedAt: String?

        /// The policy these fields record (`KeyChangePolicy.init(journalMode:days:)`).
        func keyChangePolicy() throws -> KeyChangePolicy {
            if let changedAt, RFC3339.parse(changedAt) == nil { throw KeyChangePolicyError.badChangeTime }
            return try KeyChangePolicy(journalMode: mode, days: lateFileWindowDays)
        }

        /// `changedAt` as a date (nil: absent).
        var changeTime: Date? { changedAt.flatMap(RFC3339.parse) }
    }

    /// The journal and its outgoing secret, when this device accepts it
    /// (format.md §3.3.1 "Accepting the journal", `judgeJournal`).
    ///
    /// - Throws: `rewrapJournalUnreadable` when it cannot be read or is refused.
    func readJournal() throws -> (journal: RewrapJournal, previous: VaultSecret?) {
        switch judgeJournal() {
        case .accepted(let journal, let previous): return (journal, previous)
        case .refused(let why), .unreadable(let why): throw VaultError.rewrapJournalUnreadable(why)
        }
    }

    /// Re-encrypts every revision file not yet current (format.md §3.3.1).
    /// A file is current when its header has exactly one stanza of the
    /// matching type per recipient (and no other stanzas) and its tag
    /// verifies under the current secret; such files are skipped, which is
    /// what makes a second run finish an interrupted one.
    func rewrapNotes(blobs: RewrapMethod = .reencrypt, stopAfter: Int?) throws -> RewrapReport {
        let current = try requireSecret()
        let recips = try ageRecipients()
        let expected = Self.expectedStanzas(recips)
        var report = RewrapReport()
        report.blobMethod = blobs
        for note in try noteDirectoryNames() {
            let dir = notesURL.appendingPathComponent(note)
            for name in try revisionFileNames(in: dir) {
                let path = "\(note)/\(name)"
                let file = dir.appendingPathComponent(name)
                let data: Data
                do { data = try FileIO.read(file, maxBytes: BoundedRead.maxRevisionBytes) } catch {
                    report.failures[path] = .unreadable("\(error)"); continue
                }
                let stanzas: [String: Int]
                let plain: Data
                do {
                    stanzas = try Self.stanzaCounts(data)
                    plain = try AgeFile.decrypt(data, with: identities)
                } catch {
                    report.failures[path] = .undecryptable("\(error)"); continue
                }
                let body: Data
                do {
                    _ = try BodyFraming.unframe(plain, noteId: note, filename: name, secret: current)
                    if stanzas == expected {
                        report.alreadyCurrent.append(path); continue
                    }
                    body = plain
                } catch BodyFramingError.tagMismatch {
                    // The journal's outgoing secret, then (a late file's rewrap, design §6.3) the keyring's.
                    var old = previousSecret.flatMap { try? BodyFraming.unframe(plain, noteId: note, filename: name, secret: $0) }
                    if old == nil, let fromKeyring = olderSecrets.lazy.compactMap({
                        try? BodyFraming.unframe(plain, noteId: note, filename: name, secret: $0)
                    }).first {
                        // R3 rewraps from the keyring only what this device wrote (review finding 2: another
                        // device's file under an old secret, a removed device's included, is never made current
                        // here; it waits for its writer, or for a current copy from a target).
                        if let own = lateOwnDevices, !(RevisionName(name).map { own.contains($0.device) } ?? false) {
                            report.lateSkipped.append(path); continue
                        }
                        old = fromKeyring
                    }
                    guard let old else { report.failures[path] = .tagMismatch; continue }
                    body = BodyFraming.retag(old, noteId: note, filename: name, secret: current)
                } catch {
                    report.failures[path] = .corruptBody("\(error)"); continue
                }
                if let stopAfter, report.rewrapped.count >= stopAfter { throw VaultError.interrupted }
                try FileIO.writeAtomically(try Self.encrypt(body, to: recips), to: file, replacing: true)
                report.rewrapped.append(path)
            }
            try rewrapBlobs(note: note, recipients: recips, method: blobs, report: &report, stopAfter: stopAfter)
        }
        try rewrapInbox(recipients: recips, report: &report, stopAfter: stopAfter)
        try rewrapSharedSettings(recipients: recips, report: &report, stopAfter: stopAfter)
        try rewrapNotebookRecords(recipients: recips, report: &report, stopAfter: stopAfter)
        return report
    }

    /// The number of stanzas of each type in an age file's header.
    static func stanzaCounts(_ data: Data) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for s in try AgeFile.parseHeader(data).header.stanzas { counts[s.type, default: 0] += 1 }
        return counts
    }

    /// The stanza counts of a file encrypted to exactly `recipients`
    /// (format.md §3.3.1 "complete"): one `mlkem768x25519` stanza per
    /// recipient.
    static func expectedStanzas(_ recipients: [NativeRecipient]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in recipients { counts[r.stanzaType, default: 0] += 1 }
        return counts
    }

    /// "2 mlkem768x25519", for reports.
    static func describe(_ counts: [String: Int]) -> String {
        counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    }

    // MARK: - Listing helpers

    /// Lowercase-UUID directory names under `notes/`, sorted.
    func noteDirectoryNames() throws -> [String] {
        try FileIO.entries(notesURL, directories: true, where: Self.isNoteDirectoryName)
    }

    package static func isNoteDirectoryName(_ s: String) -> Bool {
        guard let u = UUID(uuidString: s) else { return false }
        return u.uuidString.lowercased() == s
    }

    /// Canonical revision file names in a note directory (regular files only).
    func revisionFileNames(in dir: URL) throws -> [String] {
        try FileIO.entries(dir, directories: false) { n in RevisionName(n)?.filename == n }
    }
}

/// What a `Vault` and its copies last saved to the trust store.
final class TrustMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var record: RecipientsTrustRecord?

    var last: RecipientsTrustRecord? {
        get { lock.lock(); defer { lock.unlock() }; return record }
        set { lock.lock(); record = newValue; lock.unlock() }
    }
}
