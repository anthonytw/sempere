import Age
import Crypto
import Foundation

// MARK: - Key changes across devices (docs/design/device-first-sync.md §6; format.md §3.3.1)
//
// A recipient change on one device must never lose data on another, whatever
// fails (design §6.2, F1 to F19). This file holds the core pieces of that
// safety gate (phase P4a):
//
// - `KeyChangePolicy`: the mode (routine or "my key may be compromised") and
//   the late-file window, recorded in the rewrap journal (format.md §3.3.1
//   `mode`, `lateFileWindowDays`), where `rewrapPending` binds them, so a sync
//   target cannot change them.
// - `RewrapFaults`: where a test stops a change, as a crash there would.
// - `PreparedKeyChange`: a change's checks and its exact journal bytes before
//   anything is written, so the journal can claim every target first (C1).
// - The rewrap of this device's late files from its secret keyring (R3) and
//   the classification of two copies of one file (rewrap-replace, design
//   §5.2, and late files, F9), which the sync engine applies.
// - `OutgoingKeyGuard`: the rule that keeps the outgoing identity while a
//   replace is pending (F4).

/// How a key change treats files written under the old secret that arrive
/// after it (design §6.5): the mode, and how long such late files are still
/// taken in (rewrapped and placed) before they are quarantined instead.
public struct KeyChangePolicy: Hashable, Sendable, Codable {
    /// The two modes of the key-change sheet.
    public enum Mode: String, Hashable, Sendable, Codable, CaseIterable {
        /// A device is added, removed or replaced in the normal course.
        case routine
        /// "My key may be compromised": no late file is taken in, and the
        /// change propagates ahead of all other sync work.
        case compromised
    }

    /// The mode.
    public var mode: Mode
    /// Days during which late files are rewrapped and placed, counted from
    /// when the receiving device first saw the change. Always 0 in
    /// `compromised` mode.
    public var lateFileWindowDays: Int

    /// The routine default (format.md §3.3.1: an absent field means this).
    public static let defaultWindowDays = 7
    /// The longest window a journal may record.
    public static let maxWindowDays = 365

    /// Routine, 7 days.
    public static let routine = KeyChangePolicy(uncheckedMode: .routine, days: defaultWindowDays)
    /// "My key may be compromised": 0 days.
    public static let compromised = KeyChangePolicy(uncheckedMode: .compromised, days: 0)
    /// What a device that never saw a change's journal applies (design F18):
    /// an unknown policy never widens acceptance.
    public static let unknown = KeyChangePolicy(uncheckedMode: .compromised, days: 0)

    private init(uncheckedMode: Mode, days: Int) {
        mode = uncheckedMode
        lateFileWindowDays = days
    }

    /// A routine change with a window of `days` (0 to `maxWindowDays`).
    ///
    /// - Throws: `KeyChangePolicyError.windowOutOfRange`.
    public static func routine(days: Int) throws -> KeyChangePolicy {
        guard (0...maxWindowDays).contains(days) else { throw KeyChangePolicyError.windowOutOfRange(days) }
        return KeyChangePolicy(uncheckedMode: .routine, days: days)
    }

    /// The policy a journal records (format.md §3.3.1): `mode` absent means
    /// routine, `lateFileWindowDays` absent means 7 (0 when compromised). A
    /// mode this version does not know, a window outside 0 to
    /// `maxWindowDays`, or a compromised change with a window other than 0
    /// is not a journal of this version.
    ///
    /// - Throws: `KeyChangePolicyError`.
    public init(journalMode: String?, days: Int?) throws {
        let mode: Mode
        if let journalMode {
            guard let m = Mode(rawValue: journalMode) else {
                throw KeyChangePolicyError.unknownMode(String(journalMode.prefix(32)))
            }
            mode = m
        } else {
            mode = .routine
        }
        switch mode {
        case .routine:
            let d = days ?? Self.defaultWindowDays
            guard (0...Self.maxWindowDays).contains(d) else { throw KeyChangePolicyError.windowOutOfRange(d) }
            self.init(uncheckedMode: .routine, days: d)
        case .compromised:
            guard days == nil || days == 0 else { throw KeyChangePolicyError.windowOutOfRange(days ?? 0) }
            self.init(uncheckedMode: .compromised, days: 0)
        }
    }

    public init(from decoder: Decoder) throws {
        enum K: String, CodingKey { case mode, lateFileWindowDays }
        let c = try decoder.container(keyedBy: K.self)
        try self.init(journalMode: try c.decodeIfPresent(String.self, forKey: .mode),
                      days: try c.decodeIfPresent(Int.self, forKey: .lateFileWindowDays))
    }

    /// The window in seconds.
    public var window: TimeInterval { TimeInterval(lateFileWindowDays) * 86_400 }

    /// The stricter of two policies (the shorter window; compromised over routine).
    public func stricter(_ other: KeyChangePolicy) -> KeyChangePolicy {
        if mode == .compromised || other.mode == .compromised { return .compromised }
        return lateFileWindowDays <= other.lateFileWindowDays ? self : other
    }
}

/// A key-change policy outside the format (format.md §3.3.1).
public enum KeyChangePolicyError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownMode(String)
    case windowOutOfRange(Int)

    public var description: String {
        switch self {
        case .unknownMode(let m):
            return "unknown key-change mode \(String(String.UnicodeScalarView(m.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f })))"
        case .windowOutOfRange(let d):
            return "late-file window \(d) days is outside 0 to \(KeyChangePolicy.maxWindowDays) (0 in compromised mode)"
        }
    }
}

/// Where a key change stops as a crash there would (design §6.4
/// `RewrapFaults`; tests only). The `Vault` value is abandoned after the
/// throw (`VaultError.interrupted`), and the next open finds the files as
/// that crash would have left them.
public struct RewrapFaults: Hashable, Sendable {
    /// A point in K1 to K4 of design §6.1.
    public enum Point: Hashable, Sendable {
        /// After K1 (the journal is written; `vault.json` is not).
        case afterJournal
        /// After K2 (`vault.json` binds the journal; no file is rewrapped).
        case afterManifest
        /// During K3, after this many files (revisions, blobs, inbox files) were rewrapped.
        case afterFiles(Int)
        /// After K3 (every file current), before K4.
        case beforeFinish
    }

    /// Where to stop; nil runs the change to the end.
    public var stop: Point?

    public init(stop: Point? = nil) { self.stop = stop }

    /// No fault.
    public static let none = RewrapFaults()

    var stopAfterFiles: Int? {
        if case .afterFiles(let n)? = stop { return n }
        return nil
    }
}

/// A recipient change checked and ready to write: the new list and the exact
/// bytes of its `rewrap-journal.json` (format.md §3.3.1 step 1), which a sync
/// layer writes create-only to every target before the change starts (the
/// claim, design §6.1 C1). `Vault.commit` writes those same bytes (K1) and
/// binds them (K2), so each claim becomes the change's journal there.
public struct PreparedKeyChange: Sendable {
    /// The vault it belongs to.
    public let vaultId: UUID
    /// `vault.json` as it was when prepared; the change is refused if it moved.
    let base: VaultManifest
    let next: [VaultManifest.Recipient]
    /// True when the secret rotates (a removal or a replace).
    public let rotate: Bool
    let method: RewrapMethod
    /// The journal's bytes.
    public let journal: Data
    /// The mode and late-file window it records.
    public let keyChange: KeyChangePolicy

    /// The keys of the new list.
    public var nextKeys: [String] { next.map(\.key) }
    /// The keys of the list it changes.
    public var baseKeys: [String] { base.recipients.map(\.key) }
}

extension Vault {
    // MARK: Prepared changes (design §6.1 C0, C1, K1 to K4)

    /// Prepares adding `recipient` (as `addRecipient`), without writing:
    /// a journal this device refuses is moved aside first, and an unfinished
    /// change refuses (design §6.1 C0: no journal is pending).
    public mutating func prepareAddRecipient(_ recipient: NativeRecipient, label: String, added: Date = Date(),
                                             policy: RewrapPolicy = RewrapPolicy(),
                                             keyChange: KeyChangePolicy = .routine) throws -> PreparedKeyChange {
        guard recipient.isPostQuantum else { throw VaultError.classicRecipient(recipient.string) }
        try requirePreparable()
        let key = recipient.string
        guard !manifest.recipients.contains(where: { $0.key == key }) else { throw VaultError.duplicateRecipient(key) }
        var next = manifest.recipients
        next.append(.init(key: key, label: VaultManifest.Recipient.cleanLabel(label), added: added))
        return try prepareChange(next, rotate: false, policy: policy, repairing: false, keyChange: keyChange)
    }

    /// Prepares removing `recipient` (as `removeRecipient`): the secret rotates.
    public mutating func prepareRemoveRecipient(_ recipient: NativeRecipient, policy: RewrapPolicy = RewrapPolicy(),
                                                keyChange: KeyChangePolicy = .routine) throws -> PreparedKeyChange {
        try requirePreparable()
        let key = recipient.string
        guard manifest.recipients.contains(where: { $0.key == key }) else { throw VaultError.unknownRecipient(key) }
        let next = manifest.recipients.filter { $0.key != key }
        guard !next.isEmpty else { throw VaultError.lastRecipient }
        return try prepareChange(next, rotate: true, policy: policy, repairing: false, keyChange: keyChange)
    }

    /// Prepares replacing `old` by `new` (as `replaceRecipient`): the secret rotates.
    public mutating func prepareReplaceRecipient(_ old: NativeRecipient, with new: NativeRecipient, label: String? = nil,
                                                 added: Date = Date(), policy: RewrapPolicy = RewrapPolicy(),
                                                 keyChange: KeyChangePolicy = .routine) throws -> PreparedKeyChange {
        guard new.isPostQuantum else { throw VaultError.classicRecipient(new.string) }
        try requirePreparable()
        let oldKey = old.string, newKey = new.string
        guard let index = manifest.recipients.firstIndex(where: { $0.key == oldKey }) else {
            throw VaultError.unknownRecipient(oldKey)
        }
        guard !manifest.recipients.contains(where: { $0.key == newKey }) else { throw VaultError.duplicateRecipient(newKey) }
        var next = manifest.recipients
        next[index] = .init(key: newKey, label: label.map(VaultManifest.Recipient.cleanLabel) ?? next[index].label, added: added)
        return try prepareChange(next, rotate: true, policy: policy, repairing: false, keyChange: keyChange)
    }

    /// Writes a prepared change (K1 to K4): its journal, `vault.json` binding
    /// it, every file rewrapped, then the journal removed. With `keyring`,
    /// this device's outgoing secret is stored there with the change's
    /// policy before anything is written (design §6.3). An interrupted
    /// change resumes like any other (`resumeRewrap`); one stopped before
    /// `vault.json` was written left an unbound journal, which every device
    /// refuses (F2).
    ///
    /// - Throws: `VaultError.manifestCorrupt` when `vault.json` changed since
    ///   it was prepared; `VaultError.interrupted` where `faults` stops it.
    @discardableResult
    public mutating func commit(_ prepared: PreparedKeyChange, faults: RewrapFaults = .none,
                                keyring: (any SecretKeyringStore)? = nil, now: Date = Date()) throws -> RewrapReport {
        try requireWritable()
        if pendingRewrap {
            // Only a journal this device refuses (F1, F2: a claim or K1 left by a crash) gives way.
            guard case .refused = judgeJournal() else {
                throw VaultError.rewrapJournalKept("a recipient change is unfinished: finish it first")
            }
            _ = try discardRefusedJournal()
        }
        return try commitChange(prepared, faults: faults, keyring: keyring, now: now)
    }

    /// Design §6.1 C0 for this vault: complete, a list that checks, and no
    /// change pending (a journal this device refuses is moved aside).
    mutating func requirePreparable() throws {
        _ = try requireReadable()
        try requireTrustedRecipients()
        try requireCompleteCopy()
        _ = try discardJournalBlockingChange()
        if pendingRewrap {
            throw VaultError.rewrapJournalKept("a recipient change is unfinished: finish it first")
        }
    }

    // MARK: The secret keyring in a vault (design §6.3)

    /// This vault value with the secrets of `keyring` other than the
    /// current one available to `rewrapLateFiles` and `classifyCopy` (never
    /// to ordinary reads).
    public func withOlderSecrets(from keyring: SecretKeyring?) -> Vault {
        var v = self
        guard let keyring, let secret, keyring.vaultId == vaultId else { return v }
        v.olderSecrets = keyring.secrets(excluding: secret)
        return v
    }

    /// The keyring's secrets this value holds (`withOlderSecrets`).
    public var olderSecretCount: Int { olderSecrets.count }

    /// Rewraps every local file that is not current but verifies under a
    /// secret this device held before (design §6.1 R3: this device's own
    /// late files, and its stale copies of others' files), exactly as a
    /// recipient change rewraps (format.md §3.3.1 step 3): re-encrypted to
    /// the current recipients and re-tagged under the current secret; blobs
    /// named under an older secret move to their current name. Nothing that
    /// verifies under no known secret is touched (it is reported). Needs
    /// `withOlderSecrets` for rotated secrets; with none it still completes
    /// files that lack a recipient added since they were written.
    ///
    /// - Throws: the checks of `requireWritable`; `partialCopy`.
    @discardableResult
    public func rewrapLateFiles() throws -> RewrapReport {
        _ = try requireReadable()
        try requireWritable()
        try requireCompleteCopy()
        return try rewrapNotes(blobs: .reencrypt, stopAfter: nil)
    }

    // MARK: Two copies of one file (design §5.2 rewrap-replace, §6.2 F9)

    /// How one copy of a write-once file checks under this device's secrets.
    public enum CopyStatus: Hashable, Sendable {
        /// Encrypted to exactly the current recipients and tagged (a blob:
        /// named) under the current secret.
        case current(body: Data)
        /// Decrypts here and verifies, but not as current: under the current
        /// secret with other stanzas, or under an older secret (`secretIndex`
        /// 0 is the journal's outgoing secret or the newest keyring secret).
        case stale(body: Data, olderSecret: VaultSecret?)
        /// Does not decrypt or verify here.
        case invalid(String)

        /// The comparable body (§5.2 rule 3), nil when invalid.
        public var body: Data? {
            switch self {
            case .current(let b), .stale(let b, _): return b
            case .invalid: return nil
            }
        }

        public var isCurrent: Bool { if case .current = self { return true } else { return false } }
    }

    /// Classifies a revision copy for `notes/<note>/<name>`: its body is the
    /// `gzip(JSON)` bytes (format.md §4), the same for every wrap of it.
    public func classifyRevision(_ data: Data, note: UUID, name: RevisionName) -> CopyStatus {
        guard let current = secret else { return .invalid("the vault is locked") }
        let noteName = note.uuidString.lowercased()
        let stanzas: [String: Int]
        let plain: Data
        do {
            stanzas = try Self.stanzaCounts(data)
            plain = try AgeFile.decrypt(data, with: identities)
        } catch {
            return .invalid("does not decrypt with this device's key: \(error)")
        }
        let expected = ((try? ageRecipients()).map(Self.expectedStanzas)) ?? [:]
        if let u = try? BodyFraming.unframe(plain, noteId: noteName, filename: name.filename, secret: current) {
            return stanzas == expected ? .current(body: u.gzip) : .stale(body: u.gzip, olderSecret: nil)
        }
        for s in (previousSecret.map { [$0] } ?? []) + olderSecrets {
            if let u = try? BodyFraming.unframe(plain, noteId: noteName, filename: name.filename, secret: s) {
                return .stale(body: u.gzip, olderSecret: s)
            }
        }
        return .invalid("its tag verifies under no secret this device knows")
    }

    /// A revision copy re-encrypted to the current recipients and re-tagged
    /// under the current secret (what `rewrapNotes` writes for it).
    ///
    /// - Throws: `IncomingFileProblem` when it does not verify here.
    public func rewrappedRevision(_ data: Data, note: UUID, name: RevisionName) throws -> Data {
        let current = try requireSecret()
        switch classifyRevision(data, note: note, name: name) {
        case .current: return data
        case .invalid(let why): throw IncomingFileProblem(why)
        case .stale:
            let plain = try AgeFile.decrypt(data, with: identities)
            let noteName = note.uuidString.lowercased()
            var unframed: BodyFraming.Unframed?
            for s in [current] + (previousSecret.map { [$0] } ?? []) + olderSecrets {
                if let u = try? BodyFraming.unframe(plain, noteId: noteName, filename: name.filename, secret: s) {
                    unframed = u
                    break
                }
            }
            guard let unframed else { throw IncomingFileProblem("its tag verifies under no secret this device knows") }
            let body = BodyFraming.retag(unframed, noteId: noteName, filename: name.filename, secret: current)
            return try Self.encrypt(body, to: try ageRecipients())
        }
    }

    /// The older secret (journal or keyring) a revision copy verifies under
    /// and not under the current one: what makes it a late file (F9). Nil
    /// when it is current, stale under the current secret only, or invalid.
    public func lateSecret(ofRevision data: Data, note: UUID, name: RevisionName) -> VaultSecret? {
        if case .stale(_, let s?) = classifyRevision(data, note: note, name: name) { return s }
        return nil
    }

    /// Classifies a blob file copy at `url` stored under `fileName`: its body
    /// is the content's SHA-256 (§5.2 rule 3), checked in full.
    public func classifyBlob(at url: URL, fileName: String) -> CopyStatus {
        guard let current = secret else { return .invalid("the vault is locked") }
        guard let parsed = BlobName.parse(fileName) else { return .invalid("not a blob file name") }
        let secrets = [current] + (previousSecret.map { [$0] } ?? []) + olderSecrets
        let header: BlobHeader
        do {
            (header, _) = try Self.readBlobFile(url, identities: identities, secrets: secrets, expected: nil,
                                                maxContent: BlobRef.maxSize)
        } catch {
            return .invalid("not a valid blob here: \(error)")
        }
        let body = Data(header.sha256.utf8)
        switch BlobName.verify(parsed.name, digest: header.digest, secrets: secrets) {
        case 0?:
            let expected = ((try? ageRecipients()).map(Self.expectedStanzas)) ?? [:]
            return Self.stanzaCounts(blob: url) == expected ? .current(body: body) : .stale(body: body, olderSecret: nil)
        case let i? where i >= 1:
            return .stale(body: body, olderSecret: secrets[i])
        default:
            return .invalid("its name verifies under no secret this device knows")
        }
    }

    /// The file name a blob copy at `url` has under the current secret (its
    /// content's keyed name), nil when it does not verify here.
    public func currentBlobName(at url: URL, fileName: String) -> String? {
        guard let current = secret, let parsed = BlobName.parse(fileName) else { return nil }
        let secrets = [current] + (previousSecret.map { [$0] } ?? []) + olderSecrets
        guard let (header, _) = try? Self.readBlobFile(url, identities: identities, secrets: secrets, expected: nil,
                                                       maxContent: BlobRef.maxSize) else { return nil }
        return BlobName.fileName(name: BlobName.name(digest: header.digest, secret: current), kind: parsed.kind)
    }

    /// Writes the blob copy at `url` re-encrypted to the current recipients
    /// to `output` (a new file), verified in full as it streams.
    public func rewrapBlobCopy(at url: URL, to output: URL) throws {
        let peek = try Self.peekBlobFile(url, identities: identities)
        var checker = BlobPlaintextChecker()
        try AgeFile.reencrypt(contentsOf: url, to: output, identities: identities, recipients: try ageRecipients(),
                              inspect: { try checker.consume($0) })
        guard try checker.finish() == peek.header else {
            try? FileManager.default.removeItem(at: output)
            throw BlobError.contentHashMismatch
        }
    }

    /// The names of `fileNames`' contents under every older secret (journal
    /// and keyring), for telling a leftover old name of a blob this device
    /// rewrapped from a late file. Reads the first chunk of each blob.
    public func olderBlobNames(note: UUID, fileNames: [String]) -> Set<String> {
        let older = (previousSecret.map { [$0] } ?? []) + olderSecrets
        guard !older.isEmpty else { return [] }
        let dir = attURL(note)
        var out = Set<String>()
        for f in fileNames {
            guard let parsed = BlobName.parse(f),
                  let peek = try? Self.peekBlobFile(dir.appendingPathComponent(f), identities: identities) else { continue }
            for s in older {
                out.insert(BlobName.fileName(name: BlobName.name(digest: peek.header.digest, secret: s), kind: parsed.kind))
            }
        }
        return out
    }
}

/// The rule that keeps the outgoing identity while a replace is pending
/// (design §6.2 F4): until every file is rewrapped, the files not yet
/// rewrapped open only with the old key, so no app path may forget, delete
/// or overwrite it meanwhile.
public enum OutgoingKeyGuard {
    /// Why `recipient` (the key a device holds, e.g. remembered in its
    /// Keychain) must not be forgotten, deleted or overwritten now; nil when
    /// it may. It must be kept while the working copy has a recipient change
    /// pending that removes it (the journal names the change; the key is no
    /// longer listed), or while any sync target reports one
    /// (`targetsPending`), since the files there not yet rewrapped open only
    /// with it. A key still listed is the current one: forgetting it is the
    /// user's choice as before.
    public static func refusal(recipient: String, vault: Vault?, targetsPending: Bool) -> String? {
        let pendingHere = vault?.pendingRewrap ?? false
        guard pendingHere || targetsPending else { return nil }
        if let vault, vault.recipients.contains(where: { $0.key == recipient }), !targetsPending { return nil }
        return "a key change is unfinished: files not yet rewrapped open only with this key. Keep it until the "
            + "change finishes on this device and every sync target"
    }
}
