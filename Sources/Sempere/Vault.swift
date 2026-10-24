import Age
import Crypto
import Foundation

/// Errors from the vault directory layer.
public enum VaultError: Error, Hashable, Sendable {
    /// `create` needs a directory name ending in `.sempere` (format.md §1).
    case invalidVaultName(String)
    /// The path (a vault, a revision file, a key file) already exists.
    case alreadyExists(String)
    /// No `vault.json` at the given location.
    case notAVault(String)
    /// `vault.json` does not parse or breaks a rule of format.md §15.3, or this device's wrap in it does
    /// not open to a key of this vault and epoch (tampered).
    case manifestCorrupt(String)
    /// `vault.json`'s `format` is not a format identifier (`sempere/<major>`, format.md §7.1), or the
    /// manifest of a later major cannot be decoded well enough to open it read-only (§7.2).
    case unsupportedFormat(String)
    /// Not a Bech32 `age1pq1...` (MLKEM768-X25519) key.
    case invalidRecipient(String)
    /// A classic X25519 (`age1...`) key offered where a vault key goes: vaults take only post-quantum
    /// keys (format.md §3.1).
    case classicRecipient(String)
    /// Only classic X25519 identities were offered: such a key never opens a vault.
    case classicIdentity
    /// None of the identities is listed in `vault.json` (no device wrap and not the recovery key).
    case keyNotListed(String)
    /// The operation needs the vault's key; the vault was opened without identities (names only).
    case locked
    /// The vault was opened with the recovery key: it reads everything and writes nothing (design §4.3
    /// step 4, §6.1). A device joins (`sempere device init`), or takes over (KH4), to write.
    case recoveryKeyReadOnly
    /// A list change (approve, rename) needs the home device's signing keys (design §5.6): this device
    /// is not home, or its signing keys were not given.
    case notHome(String)
    /// The device (an id, a key) is already listed.
    case deviceAlreadyListed(String)
    /// No listed device has this id.
    case deviceNotFound(String)
    /// A join request refused: another vault, a key that is not post-quantum, a bad kind, an id that
    /// collides with a listed device's.
    case joinRequestRefused(String)
    /// The typed words are not the home's reply for this vault (design §6.2 step 4): the vault on
    /// storage is not the one home approved this device in.
    case replyMismatch
    /// Not a lowercase hyphenated UUID note directory name.
    case invalidNoteId(String)
    /// Another revision of this note already uses `(device, seq)`.
    case seqInUse(device: String, seq: Int)
    /// A revision's `seq` is outside 1...`RevisionName.maxSeq`, so readers would reject it.
    case seqOutOfRange(Int)
    /// A revision could not be read; `name` is its file name.
    case revision(name: String, RevisionReadError)
    /// Writers use scrypt work factor 20 for the passphrase copy (format.md §15.11); tests may use less.
    case workFactorOutOfRange(Int)
    /// The passphrase copy's scrypt work factor exceeds the reader's cap.
    case workFactorTooHigh
    /// No passphrase copy in `keys/`.
    case passphraseCopyMissing
    /// The passphrase does not decrypt the passphrase copy.
    case wrongPassphrase
    /// A key file is never written under an empty passphrase.
    case emptyPassphrase
    /// The passphrase copy decrypts but is not the plaintext of format.md §15.11, or names another vault.
    case passphraseCopyMalformed(String)
    /// Test hook: an operation stopped after the requested number of files.
    case interrupted
    /// A file to read holds more than `limit` bytes (`BoundedRead`).
    case fileTooLarge(String, limit: Int)
    /// A filesystem operation failed.
    case io(String)
    /// The vault holds newer content (format.md §7.2): a later `format`, unknown `features`, or newer
    /// revisions this vault value has read. It may be read but never written (§7.3).
    case readOnly(ReadOnlyReasons)
    /// `vault.json` does not check, or this device cannot confirm it (design §4.3): nothing is written.
    case untrustedList(ListProblem)
    /// The vault folder is a partial copy (format.md §1.2): the operation must see every file of the
    /// vault. The value is the vault's path.
    case partialCopy(String)
    /// A note of a partial copy has not received all its revisions (format.md §1.2): nothing is written
    /// to it, or deleted from it, until they arrive. The value is the note id.
    case noteIncomplete(String)
    /// This device is not on the device list of the vault's newest epoch, which it verified (design §5.5):
    /// it writes nothing (CLI exit 8). A takeover that re-admits it undoes it. The value says who removed it.
    case removedFromVault(String)
    /// The write ledger cannot be read or written (design §5.4): it fails closed, and nothing that needs it
    /// (a write, a catch-up) happens.
    case ledgerUnreadable(String)
    /// A copy could not be set aside (design §5.8): the replacement or removal that needed it does not happen.
    case setAsideFailed(String)
    /// An epoch change (removal, handoff, takeover, kit replacement) cannot be made as asked; the value says why.
    case epochChangeRefused(String)
}

/// Why one revision file could not be read, by stage. (Vault-level preconditions, such as a locked
/// vault, are `VaultError`s.)
public enum RevisionReadError: Error, Hashable, Sendable {
    /// The file could not be read from disk.
    case unreadable(String)
    /// age decryption failed (no matching identity, bad header, corrupt payload).
    case undecryptable(String)
    /// The inner HMAC tag does not match (format.md §4): tampered, replayed under another note or
    /// name, or written under another epoch's key.
    case tagMismatch
    /// The plaintext is not a valid framed gzip body.
    case corruptBody(String)
    /// The JSON does not decode as a revision, or names another note or file.
    case undecodable(String)
    /// Written by a newer version and not readable by this one (format.md §7.2, §7.4): a later body
    /// version, or a newer revision whose envelope or state does not decode. The vault is read-only
    /// once it is seen.
    case newer(String)
    /// Under an earlier epoch's key, and not taken by the acceptance rule (key-hierarchy design §5.3): set
    /// aside, never placed in the note.
    case setAside(SetAsideReason)
    /// Under a key whose epoch record has not arrived (design §5.3 rule 3): neither taken nor set aside yet.
    case pending
}

/// A vault directory (`*.sempere`, format.md §1) opened with zero or more age identities.
///
/// Under the key hierarchy (format.md §15; phase KH2: single-epoch vaults) `vault.json` wraps the
/// epoch's key `K_e` once per listed key: one entry per device and one for the recovery key. Opened with
/// a device's key, the vault reads and writes notes; with the recovery key it only reads; without
/// identities it is locked and lists names only. Every file is encrypted to the vault identity `V_e`
/// derived from `K_e`, in one stanza, and tagged under keys derived from it.
public struct Vault: Sendable {
    /// What opened the vault.
    public enum Opener: Hashable, Sendable {
        /// No key: names only.
        case locked
        /// A listed device's key; the value is its fingerprint.
        case device(Data)
        /// The recovery key: read-only.
        case recovery
    }

    /// The `.sempere` directory.
    public let url: URL
    /// The manifest as last read or written.
    public internal(set) var manifest: EpochManifest
    /// The identities that open the vault's files: the vault identity `V_e` once unlocked, else none.
    let identities: [any AgeIdentity]
    /// The identities the vault was opened with (a device key, or the recovery key).
    public let unlockIdentities: [any AgeIdentity]
    /// The epoch key `K_e`; nil when locked.
    private(set) var secret: VaultEpochKey?
    /// What opened the vault.
    public internal(set) var openedWith: Opener = .locked
    /// This device's signing keys, when given and they are its entry's: needed by list changes, which
    /// only home makes (design §5.6).
    let signing: (any AuthorSigner)?
    /// The notes whose newer revisions this vault (or a copy) has read (format.md §7.3); shared by
    /// every copy.
    let readOnlyLatch = ReadOnlyLatch()
    /// Revision files decrypted by this vault (and its copies): what tests count to check that a path
    /// does not read a note twice.
    let revisionDecrypts = WorkCounter()
    /// `revisionDecrypts` so far, for the app's read-cost tests (perf audit P50, P53): files are
    /// decrypted by the vault identity, so an identity the tests wrap no longer sees them.
    public var revisionDecryptCount: Int { revisionDecrypts.value }
    /// Revision plaintext `loadForCompaction` holds between its decodes, and its peak (tests).
    let plainHeld = ByteGauge()
    /// How `vault.json` checked when the vault was unlocked or last changed (design §4.3);
    /// `.notChecked` while locked.
    public internal(set) var listStatus: ListStatus = .notChecked
    /// Where this device keeps its trust record (format.md §15.10); nil keeps none (tests).
    var trustStore: (any EpochTrustStore)?
    /// The root the vault was opened against (`open(…, root:)`), kept for `reopened()`.
    var givenRoot: Data?
    /// The trust record this value (and its copies) last saved.
    let trustMemo = TrustMemo()
    /// Above epoch 1: the keys of the earlier epochs of the chain, read from `epochs/` as readers need them
    /// (design §5.3). Nil at epoch 1 and while locked.
    var keyring: EpochKeyring?
    /// Above epoch 1: the chain of the current epoch's record, verified at open (nil when it did not verify).
    public internal(set) var verifiedChain: EpochChain.Verified?
    /// Pinned epochs that the chain this value follows dropped (a takeover, design §5.6).
    public internal(set) var droppedEpochs: [Data] = []
    /// A verified prefix of the chain to pin before a takeover by a newer kit counts (`ListCheck.pinnable`).
    var pinnable: EpochChain.Verified?
    /// Set at open when this device's sightings (design §5.5, KH4) hold a later epoch it verified whose kept
    /// chain does not list it: why. Every write throws `removedFromVault` with it.
    public internal(set) var unlistedNotice: String?
    /// Set at open when this device's sightings hold a later epoch it cannot verify yet (design §4.3
    /// "unverified-pending"): why, and where it was seen. It writes locally; its sync runs upload nothing new.
    public internal(set) var waitingNotice: String?
    /// True when `vault.json` is a direct child of the pinned epoch whose record has not arrived (design §4.3
    /// step 2): followed, not pinned, older files pending, catch-up and device changes wait for the record.
    public var isRecordPending: Bool { listStatus == .verified(.newEpochRecordPending) }
    /// This device's write ledger (design §5.4); nil keeps none (tests, readers).
    public internal(set) var ledger: (any WriteLedgerStore)?
    /// Where this device sets files aside (design §5.8); nil keeps none (tests, readers).
    public internal(set) var setAsideStore: SetAsideStore?
    /// Test seam: where an epoch change or a catch-up stops, as a crash there would (`EpochFaults`).
    var faults = EpochFaults()
    /// The epoch keys this value (and its copies) gave its ledger.
    let ledgerMemo = LedgerMemo()
    /// Whether this value (and its copies) caught up to its epoch.
    let catchUpMemo = CatchUpMemo()

    // `package`: SempereWebDAV walks the same layout.
    package static let manifestName = "vault.json"
    package static let keysName = "keys"
    package static let notesName = "notes"
    package static let epochsName = "epochs"
    package static let joinsName = "joins"
    /// The re-encryption journal (format.md §15.8, KH6): a mutable root file.
    package static let journalName = ReencryptJournal.fileName

    var manifestURL: URL { url.appendingPathComponent(Self.manifestName) }
    var keysURL: URL { url.appendingPathComponent(Self.keysName) }
    var notesURL: URL { url.appendingPathComponent(Self.notesName) }
    var epochsURL: URL { url.appendingPathComponent(Self.epochsName) }
    var joinsURL: URL { url.appendingPathComponent(Self.joinsName) }

    /// `vaultId` from the manifest.
    public var vaultId: UUID { manifest.vaultId }
    /// The vault's root fingerprint (format.md §15.2, design §4.2): printed on the kit.
    public var root: Data { manifest.root }
    /// When the vault was created; nil when `created` does not parse.
    public var created: Date? { RFC3339.parse(manifest.created) }
    /// The listed devices, in list order.
    public var devices: [EpochKeyEntry] { manifest.devices }
    /// True when opened without a listed key: no epoch key, names only.
    public var isLocked: Bool { secret == nil }
    /// True when note files can be decrypted and verified.
    public var canRead: Bool { secret != nil }
    /// True when opened with the recovery key (read-only).
    public var isRecoveryOpen: Bool { openedWith == .recovery }
    /// The fingerprint of the device this vault was opened as; nil when locked or opened with the
    /// recovery key.
    public var deviceFingerprint: Data? {
        if case .device(let fp) = openedWith { return fp }
        return nil
    }
    /// The entry of the device this vault was opened as.
    public var deviceEntry: EpochKeyEntry? {
        guard let fp = deviceFingerprint else { return nil }
        return manifest.devices.first { $0.fingerprint == fp }
    }
    /// The `age1pq1…` recipients of the identities the vault was opened with, for a caller that names
    /// the key it unlocked with.
    public var identityRecipients: Set<String> {
        Set(unlockIdentities.compactMap { Self.recipientString(of: $0) })
    }
    /// True when this vault was opened as the home device with its signing keys (design §5.6): it may
    /// approve and rename devices.
    public var isHome: Bool { deviceFingerprint == manifest.home && signing != nil }

    /// Why this vault is read-only (format.md §7.3): its manifest's newer `format` or unknown
    /// `features`, and the notes whose newer revisions this vault value (or any copy of it) has read so
    /// far. Empty when writable.
    public var readOnlyReasons: ReadOnlyReasons {
        Self.readOnlyReasons(manifest, newerNotes: readOnlyLatch.newerNotes)
    }

    /// True when the vault must not be written (`readOnlyReasons` not empty).
    public var isReadOnly: Bool { !readOnlyReasons.isEmpty }

    static func readOnlyReasons(_ manifest: EpochManifest, newerNotes: [UUID] = []) -> ReadOnlyReasons {
        ReadOnlyReasons(vaultFormat: SempereFormat.isNewer(manifest.format) ? manifest.format : nil,
                        unknownFeatures: manifest.unknownFeatures, newerNotes: newerNotes)
    }

    /// Throws `VaultError.readOnly` when the vault holds newer content (format.md §7.2, §7.3).
    public func requireNotReadOnly() throws {
        let reasons = readOnlyReasons
        if !reasons.isEmpty { throw VaultError.readOnly(reasons) }
    }

    /// Every write calls it. Throws `VaultError.readOnly` for a vault holding newer content, checked
    /// first, then `locked`, `recoveryKeyReadOnly` for a vault opened with the recovery key, and
    /// `untrustedList` when `vault.json` did not check (design §4.3). A writer keeps a trust record.
    public func requireWritable() throws {
        try requireNotReadOnly()
        switch openedWith {
        case .locked: throw VaultError.locked
        case .recovery: throw VaultError.recoveryKeyReadOnly
        case .device: break
        }
        // A later epoch this device verified does not list it (design §5.5): it writes nothing.
        if let unlistedNotice { throw VaultError.removedFromVault(unlistedNotice) }
        // A takeover that waits for its kit to be pinned: pin the chain up to it now, so the next open
        // takes it (design §5.6 rule 3); this write is still refused.
        if listStatus.problem != nil, pinnable != nil { try? pinDeferredPrefix() }
        try requireTrustedList()
        if case .verified = listStatus { try rememberList() }
        // The first write at a new epoch catches this device's own files up first (design §5.4).
        try catchUpIfNeeded()
    }

    /// Records that `note` holds newer content (format.md §7.3): from now on every write through this
    /// vault, or any copy of it, is refused.
    func noteNewerContent(in note: UUID) { readOnlyLatch.record(note) }

    /// Throws `VaultError.untrustedList` when `listStatus` is refused. Callers that encrypt to the vault
    /// outside `requireWritable` (capture profiles) call it.
    public func requireTrustedList() throws {
        if let problem = listStatus.problem { throw VaultError.untrustedList(problem) }
    }

    /// Test seam (internal): a blob rename stops (`VaultError.interrupted`) after the new name is in
    /// place and before the old one is deleted, as a crash there would. Never set outside tests.
    var crashAfterBlobPlace = false

    // MARK: - Create and open

    /// Creates a vault (format.md §15; design §3, §5.2.1): epoch 1 with a fresh `K_1`, its record in
    /// `epochs/`, and `vault.json` listing this device (its home) and the recovery key, each with a wrap
    /// of `K_1`, signed by the device. With a passphrase, also the passphrase copy of the recovery key
    /// in `keys/` (§15.11). `keys/` and `notes/` are created empty.
    ///
    /// The recovery identity is used to wrap the key and to derive its signing keys' public halves; it
    /// is not stored (the caller prints it as the kit), except in the passphrase copy.
    ///
    /// - Parameters:
    ///   - url: a directory whose name ends in `.sempere`; it may exist but must not hold a `vault.json`.
    ///   - device: this device's keys; the vault is opened as it.
    ///   - deviceName: the device's name (cleaned, at most 40 characters).
    ///   - kind: `ipad`, `iphone`, `mac`, `cli`, or another lowercase word of 1 to 32 letters.
    ///   - recovery: the recovery key `R`.
    ///   - recoveryPassphrase: writes the passphrase copy when given (not empty).
    ///   - workFactor: the copy's scrypt work factor; writers use 20 (format.md §15.11), tests less.
    ///   - vaultId, created: fixed values for reproducible fixtures.
    ///   - trust: this device's trust records; the new vault's is saved there.
    ///   - label: the vault's display name (format.md §2 `label`), cleaned; nil or empty: none.
    public static func create(at url: URL, device: DeviceKeys, deviceName: String, kind: String = "cli",
                              recovery: MLKEM768X25519Identity, recoveryPassphrase: String? = nil,
                              workFactor: Int = RecoveryPassphraseCopy.workFactor, vaultId: UUID = UUID(),
                              created: Date = Date(), trust: (any EpochTrustStore)? = nil,
                              label: String? = nil, ledger: (any WriteLedgerStore)? = nil,
                              setAside: SetAsideStore? = nil) throws -> Vault {
        guard url.lastPathComponent.hasSuffix(".sempere"), url.lastPathComponent.count > ".sempere".count else {
            throw VaultError.invalidVaultName(url.lastPathComponent)
        }
        guard JoinRequest.isValidKind(kind) else { throw VaultError.joinRequestRefused("kind \(kind)") }
        if let recoveryPassphrase, recoveryPassphrase.isEmpty { throw VaultError.emptyPassphrase }
        guard (1...RecoveryPassphraseCopy.workFactor).contains(workFactor) else {
            throw VaultError.workFactorOutOfRange(workFactor)
        }
        let manifestURL = url.appendingPathComponent(manifestName)
        guard !FileIO.exists(manifestURL) else { throw VaultError.alreadyExists(manifestURL.path) }

        let stamp = RFC3339.string(created)
        let key = VaultEpochKey.random()
        let root = try VaultRoot.fingerprint(vaultId: vaultId, epochOne: key)
        let recoverySigning = try DeviceSigningKeys.recovery(identity: recovery)
        let recoverySign = try recoverySigning.publicKeys()
        let recoveryKey = recovery.recipient.string
        let recoveryFingerprint = KeyFingerprint.recovery(key: recoveryKey, signP256: recoverySign.p256Hex,
                                                          signMLDSA65: recoverySign.mldsa65Hex)
        // The creator's entry carries its own addSig (format.md §15.4): it is in epoch 1's first list.
        let claim = EntryClaim(key: device.key, sign: device.sign, kind: kind, added: stamp, addedEpoch: 1,
                               addedBy: device.id)
        let deviceEntry = EpochKeyEntry(
            role: .device, key: device.key, id: device.id, sign: device.sign, kind: kind, added: stamp, addedEpoch: 1,
            addedBy: device.id, addSig: try device.signing.sign(AuthorMessage.entry(vaultId: vaultId, claim)),
            name: DeviceName.clean(deviceName),
            wrap: try EpochKeyWrap.seal(key, vaultId: vaultId, epoch: 1, to: device.nativeIdentity.recipient))
        let recoveryEntry = EpochKeyEntry(
            role: .recovery, key: recoveryKey, sign: recoverySign, added: stamp, name: "Recovery kit",
            wrap: try EpochKeyWrap.seal(key, vaultId: vaultId, epoch: 1, to: .mlkem768x25519(recovery.recipient)))

        // Epoch 1's chain entry, signed by its creator (its home), and its record.
        var entry = ChainEntry(epoch: 1, epochId: key.epochId, parent: nil, linkPublicKeys: try LinkPublicKeys(epochKey: key),
                               link: nil, reason: EpochReason.create.rawValue,
                               list: [device.fingerprint, recoveryFingerprint].sorted { $0.lexicographicallyPrecedes($1) },
                               parentList: [], author: ChainAuthor(key: device.key, sign: device.sign),
                               epochSig: Self.placeholderSignature, recovery: recoveryFingerprint, home: device.fingerprint)
        entry.epochSig = try device.signing.sign(entry.epochMessage(vaultId: vaultId, root: root))
        let record = EpochRecord(vaultId: vaultId, root: root, epoch: 1, epochId: key.epochId, parent: nil, chain: [entry],
                                 created: stamp, by: device.id, reason: EpochReason.create.rawValue)
        let recordFile = try record.seal(key: key)

        var m = EpochManifest(
            format: SempereFormat.identifier, vaultId: vaultId, created: stamp, root: root, epoch: 1, epochId: key.epochId,
            parent: nil, epochRecord: Self.epochsName + "/" + record.fileName,
            epochRecordHash: Data(SHA256.hash(data: recordFile)), keys: [deviceEntry, recoveryEntry], listTag: "",
            epochLink: nil, epochAuthor: device.id, epochSig: entry.epochSig, markersTag: "", author: device.id,
            authorSig: Self.placeholderSignature, features: [], label: VaultLabelText.cleanVaultLabel(label),
            reencryptPending: nil, parentList: [], epochReason: EpochReason.create.rawValue, home: device.fingerprint,
            recoverySig: nil)
        try Self.seal(&m, key: key, signing: device.signing, author: device.id)

        try FileIO.createDirectory(url)
        try FileIO.createDirectory(url.appendingPathComponent(keysName))
        try FileIO.createDirectory(url.appendingPathComponent(notesName))
        try FileIO.createDirectory(url.appendingPathComponent(epochsName))
        // The record is durable under its final name before vault.json names it (design §5.2 step 4).
        try FileIO.writeAtomically(recordFile, to: url.appendingPathComponent(m.epochRecord), replacing: false)
        if let recoveryPassphrase {
            let copy = RecoveryPassphraseCopy(created: stamp, vaultId: vaultId, root: root, identity: recovery)
            try FileIO.writeAtomically(try copy.seal(passphrase: recoveryPassphrase, workFactor: workFactor),
                                       to: url.appendingPathComponent(try copy.path()), replacing: false)
        }
        let written = try writeManifest(m, to: manifestURL, replacing: false)
        var vault = Vault(url: url, manifest: written, identities: [try key.vaultIdentity()],
                          unlockIdentities: [device.nativeIdentity], secret: key, signing: device.signing,
                          trustStore: trust)
        vault.openedWith = .device(device.fingerprint)
        vault.ledger = ledger
        vault.setAsideStore = setAside
        vault.listStatus = .verified(.firstUse)
        try? vault.rememberList()   // else saved by the first write (requireWritable)
        return vault
    }

    /// Opens a vault. With identities, unwraps `K_e` from the entry of the first listed device key among
    /// them, else from the recovery entry (read-only); with none, opens locked (names only).
    ///
    /// `vault.json` is then checked (design §4.3, `listStatus`) against this device's trust record in
    /// `trust` and against `root` when given (the kit's, the reply code's, `--root`). A refused list does
    /// not stop the open: reading works, writing throws `VaultError.untrustedList`.
    ///
    /// - Parameters:
    ///   - signing: this device's signing keys, for list changes on home; ignored unless they are the
    ///     signing keys of the entry the vault opens with.
    /// - Throws: `notAVault`, `manifestCorrupt` (also for a wrap of this device that does not open to a
    ///   key of this vault), `unsupportedFormat`, `keyNotListed`; `classicIdentity` when only X25519
    ///   identities are given.
    public static func open(at url: URL, identities: [any AgeIdentity] = [], signing: (any AuthorSigner)? = nil,
                            trust: (any EpochTrustStore)? = nil, root expectedRoot: Data? = nil,
                            ledger: (any WriteLedgerStore)? = nil, setAside: SetAsideStore? = nil) throws -> Vault {
        let manifestURL = url.appendingPathComponent(manifestName)
        guard FileIO.exists(manifestURL) else { throw VaultError.notAVault(url.path) }
        let manifestBytes = readsWithoutLinks(url)
            ? try BoundedRead.contents(under: url, manifestName, maxBytes: BoundedRead.maxManifestBytes)
            : try FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes)
        let manifest = try readManifest(manifestBytes)
        var locked = Vault(url: url, manifest: manifest, identities: [], unlockIdentities: identities, secret: nil,
                           signing: nil, trustStore: trust)
        locked.ledger = ledger
        locked.setAsideStore = setAside
        guard !identities.isEmpty else { return locked }
        let held = Set(identities.compactMap(recipientString))
        let opener: Opener
        let entry: EpochKeyEntry
        if let device = manifest.devices.first(where: { held.contains($0.key) }) {
            opener = .device(device.fingerprint); entry = device
        } else if let recovery = manifest.recoveryEntry, held.contains(recovery.key) {
            opener = .recovery; entry = recovery
        } else {
            if identities.allSatisfy(Self.isClassic) { throw VaultError.classicIdentity }
            // A device this vault listed before: removed by a device change it can verify (design §5.5).
            if let notice = removalNotice(manifest, held: held, signing: signing, trust: trust) {
                throw VaultError.removedFromVault(notice)
            }
            // A device this vault listed when it pinned an earlier epoch, which missed more than one change: it
            // cannot verify who left it out (the records are under keys it does not hold), so it is not told it
            // was removed (an unverified epoch never counts as a removal), but neither that it never joined.
            if let trust, let record = try? trust.record(for: manifest.vaultId), let pinned = record.pinned,
               record.root == manifest.root, manifest.epoch > pinned.epoch,
               record.list.contains(where: { $0.role == EpochKeyEntry.Role.device.rawValue && held.contains($0.key) }) {
                throw VaultError.keyNotListed("this device is not on the device list of epoch \(manifest.epoch) (it last "
                    + "verified epoch \(pinned.epoch)), and it cannot verify the changes between them: it holds none of their "
                    + "keys, so it reads nothing newer and writes nothing. If it was removed by mistake, a takeover with the "
                    + "recovery kit undoes it")
            }
            throw VaultError.keyNotListed("none of the keys is listed in vault.json: this device has not joined the vault")
        }
        let key: VaultEpochKey
        do { key = try EpochKeyWrap.open(entry.wrap, with: identities, vaultId: manifest.vaultId, epoch: manifest.epoch) } catch {
            throw VaultError.manifestCorrupt("this device's wrap does not open to a key of this vault and epoch "
                + "(tampered): \(error)")
        }
        var vault = Vault(url: url, manifest: manifest, identities: [try key.vaultIdentity()], unlockIdentities: identities,
                          secret: key, signing: entry.role == .device && signing.flatMap({ try? $0.publicKeys() }) == entry.sign
                            ? signing : nil, trustStore: trust)
        vault.ledger = ledger
        vault.setAsideStore = setAside
        vault.openedWith = opener
        vault.givenRoot = expectedRoot
        let recordRead = readCurrentRecord(url, manifest: manifest, key: key)
        let check = listCheck(manifest, key: key, trust: trust, root: expectedRoot, record: recordRead)
        vault.listStatus = check.status
        vault.verifiedChain = check.chain
        vault.droppedEpochs = check.dropped
        vault.pinnable = check.pinnable
        // Earlier keys only from a chain that verified (review S2): an untrusted vault.json is still read,
        // but never launders files under older keys through its record's sealed sets.
        let chainTrusted = check.chain != nil
            && (check.status.problem == nil || check.status.problem?.reason == .rootUnconfirmed)
        if case .read(let record) = recordRead, chainTrusted {
            vault.keyring = EpochKeyring(url: url, vaultId: manifest.vaultId, chainIds: record.chain.map(\.epochId),
                                         parent: record.parent, withoutLinks: readsWithoutLinks(url))
        } else if manifest.epoch > 1 {
            // The record has not arrived: earlier keys are unknown, files under them pending (design §5.3 rule 3).
            vault.keyring = EpochKeyring(url: url, vaultId: manifest.vaultId, chainIds: [],
                                         parent: EpochRecordParent(epoch: manifest.epoch - 1, epochId: manifest.parent ?? Data(),
                                                                   key: nil, sealed: [:]),
                                         withoutLinks: true)
        }
        // Keys of epochs off the chain that this device wrote under (its ledger's keyring): their files are
        // set aside, and its own are caught up (design §5.4).
        if let ledger, case .device = opener, let held = try? ledger.epochKeys() {
            var onChain = Set(vault.verifiedChain?.entries.map(\.epochId) ?? [manifest.epochId])
            // A direct child whose record has not arrived: the pinned chain's epochs are on its chain too (their
            // files are pending, never set aside as off the chain).
            if vault.isRecordPending { onChain.formUnion(vault.trustedRecord()?.chain.map(\.epochId) ?? []) }
            let off = held.filter { !onChain.contains($0.key.epochId) && $0.key.epochId != key.epochId }
            if !off.isEmpty {
                if vault.keyring == nil {
                    vault.keyring = EpochKeyring(url: url, vaultId: manifest.vaultId, chainIds: [manifest.epochId], parent: nil,
                                                 withoutLinks: true)
                }
                vault.keyring?.addOffChain(off.map { ($0.epoch, $0.key) })
            }
        }
        // The earlier keys a re-encryption record does not carry (KH6, design §7.2).
        if chainTrusted { vault.attachReencryptKeys() }
        // Later epochs this device saw on a sync target and did not take (KH4, design §4.3, §5.5).
        if case .device = opener, trust != nil {
            let notices = vault.sightingNotices()
            vault.unlistedNotice = notices.unlisted
            vault.waitingNotice = notices.waiting
        }
        return vault
    }

    /// The `age1pq1…` (or `age1…`) recipient of an identity, when it is a native one.
    static func recipientString(of identity: any AgeIdentity) -> String? {
        if let native = identity as? NativeIdentity { return native.recipient.string }
        if let pq = identity as? MLKEM768X25519Identity { return pq.recipient.string }
        return nil
    }

    /// Parses and validates manifest bytes (format.md §15.3; a later major: §7.2).
    static func readManifest(_ data: Data) throws -> EpochManifest {
        let manifest: EpochManifest
        do { manifest = try EpochManifest.parse(data) } catch {
            // A later major that does not decode cannot be opened even read-only (format.md §7.2).
            // So does one whose `format` is no format identifier (§7.1).
            if let format = EpochManifest.peekFormat(data), SempereFormat.isNewer(format) || SempereFormat.major(of: format) == nil {
                throw VaultError.unsupportedFormat(format)
            }
            throw VaultError.manifestCorrupt("\(error)")
        }
        guard let major = SempereFormat.major(of: manifest.format) else { throw VaultError.unsupportedFormat(manifest.format) }
        // Up to this major every key is post-quantum (format.md §3.1): `parse` checked the prefix; each must
        // also parse. A later major may list types this version does not know (opened read-only, §7.3).
        for k in manifest.keys where major <= SempereFormat.major {
            guard let r = try? NativeRecipient(string: k.key), r.isPostQuantum else {
                throw VaultError.manifestCorrupt("invalid key \(ListProblem.abbreviate(k.key))")
            }
        }
        return manifest
    }

    /// Writes the manifest atomically and returns it as it reads back.
    static func writeManifest(_ m: EpochManifest, to url: URL, replacing: Bool) throws -> EpochManifest {
        let data = try m.encoded()
        try FileIO.writeAtomically(data, to: url, replacing: replacing)
        return try EpochManifest.parse(data)
    }

    /// Fills `m`'s `listTag` and `markersTag` under `key` and signs it as `author` (home, design §5.6).
    static func seal(_ m: inout EpochManifest, key: VaultEpochKey, signing: any AuthorSigner, author: String) throws {
        m.listTag = EpochListTag.tag(key: key, vaultId: m.vaultId, root: Hex.encode(m.root), epoch: m.epoch,
                                     epochId: Hex.encode(m.epochId), epochRecordHash: Hex.encode(m.epochRecordHash),
                                     entries: m.keys.map(\.listEntry))
        guard let markers = EpochManifest.markersTag(key: key, vaultId: m.vaultId, format: m.format, features: m.features) else {
            throw VaultError.manifestCorrupt("a format or feature holds a NUL")
        }
        m.markersTag = markers
        m.author = author
        m.authorSig = try signing.sign(m.manifestMessage)
    }

    /// `m` re-tagged and re-signed by this vault's home device (opened as home, with its signing keys) and
    /// written as `vault.json`, for tests in this package that change a field the way a (newer) writer
    /// would. Never a path of the app or the CLI.
    package func writeResealedManifest(_ m: EpochManifest) throws {
        guard let secret, let signing else { throw VaultError.notHome("needs the home device's keys") }
        var out = m
        try Self.seal(&out, key: secret, signing: signing, author: m.author)
        _ = try Self.writeManifest(out, to: manifestURL, replacing: true)
    }

    /// A signature of the right sizes, replaced before anything is written.
    static var placeholderSignature: AuthorSignature {
        // 64 and 3309 bytes by construction.
        guard let s = AuthorSignature(p256: Data(count: AuthorSignature.p256Size),
                                      mldsa65: Data(count: AuthorSignature.mldsa65Size)) else { preconditionFailure("sizes") }
        return s
    }

    /// The `vault.json` on disk, refused unless it is still the version this value holds (but for the
    /// label, which no signature covers): a list change starts from the list it was asked against.
    func requireUnchangedOnDisk() throws -> EpochManifest {
        let disk = try Self.readManifest(FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))
        // A newer vault.json synced in since open makes the vault read-only (format.md §7.3).
        let reasons = Self.readOnlyReasons(disk)
        if !reasons.isEmpty { throw VaultError.readOnly(reasons) }
        var a = disk, b = manifest
        a.label = nil; b.label = nil
        guard a == b else { throw VaultError.manifestCorrupt(VaultError.changedSinceOpened) }
        return disk
    }

    /// An X25519 (not post-quantum) age identity.
    static func isClassic(_ identity: any AgeIdentity) -> Bool {
        if identity is X25519Identity { return true }
        if let native = identity as? NativeIdentity { return !native.isPostQuantum }
        return false
    }

    /// The vault identity's recipient `v_e`, which every file of the epoch is encrypted to.
    func vaultRecipient() throws -> NativeRecipient {
        guard let secret else { throw VaultError.locked }
        if Self.epochMutations.contains(.writeUnderOldKey), let older = keyring?.all().first {
            return .mlkem768x25519(try older.key.vaultIdentity().recipient)
        }
        return .mlkem768x25519(try secret.vaultIdentity().recipient)
    }

    /// Every vault write encrypts with this: one stanza, to `v_e` (format.md §15.2).
    func encrypt(_ data: Data, armor: Bool = false) throws -> Data {
        try AgeFile.encrypt(data, to: [try vaultRecipient()], armor: armor)
    }

    /// The recipients every vault file is encrypted to: the vault identity's `v_e` alone.
    func ageRecipients() throws -> [NativeRecipient] { [try vaultRecipient()] }

    /// The stanza counts of a file encrypted to exactly `recipients`: one stanza per recipient.
    static func expectedStanzas(_ recipients: [NativeRecipient]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in recipients { counts[r.stanzaType, default: 0] += 1 }
        return counts
    }

    /// Encrypts to `recipients` (a capture profile's `v_e`, which seals without the key): post-quantum
    /// only (format.md §3.1), else `classicRecipient`.
    static func encrypt(_ data: Data, to recipients: [NativeRecipient]) throws -> Data {
        if let classic = recipients.first(where: { !$0.isPostQuantum }) { throw VaultError.classicRecipient(classic.string) }
        return try AgeFile.encrypt(data, to: recipients)
    }

    func requireSecret() throws -> VaultEpochKey {
        guard let secret else { throw VaultError.locked }
        return secret
    }

    /// The key, for operations that also decrypt note files.
    func requireReadable() throws -> VaultEpochKey { try requireSecret() }

    // MARK: - Listing helpers

    /// Lowercase-UUID directory names under `notes/`, sorted.
    func noteDirectoryNames() throws -> [String] {
        try FileIO.entries(notesURL, directories: true, where: Self.isNoteDirectoryName)
    }

    /// `<epoch>-<16 lowercase hex>.epoch.age` (format.md §15.6); other names in `epochs/` are unknown files.
    public static func isEpochRecordFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".epoch.age") else { return false }
        let parts = name.dropLast(".epoch.age".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let n = Int(parts[0]), n >= 1, String(n) == parts[0], parts[1].count == 16 else { return false }
        return parts[1].allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    package static func isNoteDirectoryName(_ s: String) -> Bool {
        guard let u = UUID(uuidString: s) else { return false }
        return u.uuidString.lowercased() == s
    }

    /// Canonical revision file names in a note directory (regular files only).
    func revisionFileNames(in dir: URL) throws -> [String] {
        try FileIO.entries(dir, directories: false) { n in RevisionName(n)?.filename == n }
    }

    /// The number of stanzas of each type in an age file's header.
    static func stanzaCounts(_ data: Data) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for s in try AgeFile.parseHeader(data).header.stanzas { counts[s.type, default: 0] += 1 }
        return counts
    }

    /// "1 mlkem768x25519", for reports.
    static func describe(_ counts: [String: Int]) -> String {
        counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    }
}
