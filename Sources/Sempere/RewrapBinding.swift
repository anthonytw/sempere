import Age
import Crypto
import Foundation

// Bound rewrap journals and finished rotations (format.md §3.3.1 "Accepting
// the journal"; security review 2026-10, S0, S1, S4, S9, S19).
//
// `rewrap-journal.json` is plaintext, and `secretLink` stays in `vault.json`
// until the next rotation. A removed device holds the outgoing secret, so the
// link alone cannot tell an unfinished rotation from a finished one: such a
// device could plant (or replay) a journal at any time and have its old secret
// accepted again. Two layers close that:
//
// 1. `rewrapPending` in `vault.json`, an HMAC under the *new* secret over the
//    journal's bytes, written with the rotation and removed when it finishes:
//    a journal counts only while `vault.json` binds it.
// 2. `rewrapFinished` in this device's trust record: once the device saw the
//    current secret with nothing pending, no journal counts again, whatever a
//    `vault.json` put back says.

extension RecipientsAuth {
    static let rewrapPendingInfo = "sempere/1 rewrap pending key"

    /// `"sempere/1" ‖ 0 ‖ "rewrap pending" ‖ 0 ‖ vaultId ‖ 0 ‖ SHA-256(journal)`.
    static func rewrapPendingMessage(vaultId: UUID, journal: Data) -> Data {
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "rewrap pending".utf8)
        m.append(0); m.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        m.append(0); m.append(contentsOf: SHA256.hash(data: journal))
        return m
    }

    /// `rewrapPending` (lowercase hex) binding `journal`'s bytes to the vault
    /// under `secret`, the secret the rotation moved to (format.md §3.3.1).
    public static func rewrapPending(vaultId: UUID, journal: Data, secret: VaultSecret) -> String {
        Hex.encode(HMAC<SHA256>.authenticationCode(for: rewrapPendingMessage(vaultId: vaultId, journal: journal),
                                                   using: derive(secret, rewrapPendingInfo)))
    }

    /// True when `tag` is 64 lowercase hex digits binding `journal` under `secret`.
    public static func verifyRewrapPending(_ tag: String, vaultId: UUID, journal: Data, secret: VaultSecret) -> Bool {
        guard let given = Hex.decode(tag), given.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: rewrapPendingMessage(vaultId: vaultId, journal: journal),
                                                      using: derive(secret, rewrapPendingInfo))
    }
}

/// Why a `rewrap-journal.json` received from a sync server may not replace
/// (or become) the local one (format.md §3.3.1 "Refused journals").
public enum IncomingJournalProblem: Hashable, Sendable {
    /// This device refuses the incoming journal: drop it.
    case refused(String)
    /// The local journal is kept (it may hold the only copy of the outgoing
    /// secret); the incoming one may be kept beside it as a conflict copy.
    case keepLocal(String)

    public var message: String {
        switch self {
        case .refused(let why): return "the incoming rewrap journal is refused: \(why)"
        case .keepLocal(let why): return why
        }
    }
}

extension Vault {
    /// How this device judges a rewrap journal (format.md §3.3.1).
    enum JournalVerdict {
        /// Written by this vault's unfinished change; `previous` is the
        /// outgoing secret when it rotated.
        case accepted(RewrapJournal, previous: VaultSecret?)
        /// Read, and not (or no longer) this vault's unfinished change: it
        /// gives no secret, and may be discarded.
        case refused(String)
        /// Could not be read now (I/O, the vault is locked): never discarded.
        case unreadable(String)
    }

    /// The journal's verdict for a reader holding `secret` under `manifest`,
    /// with this device's trust record (format.md §3.3.1 rules 1–3).
    static func judgeJournal(bytes data: Data, manifest: VaultManifest, secret: VaultSecret, identities: [any AgeIdentity],
                             record: RecipientsTrustRecord?) -> JournalVerdict {
        let j: RewrapJournal
        do { j = try InkJSON.decoder().decode(RewrapJournal.self, from: data) } catch {
            return .refused("not a rewrap journal: \(error)")
        }
        guard let armored = j.previousVaultSecret else { return .accepted(j, previous: nil) }
        let previous: VaultSecret
        do { previous = try decryptSecret(armored, with: identities) } catch {
            return .refused("previous secret: \(error)")
        }
        // The current secret: a change interrupted before vault.json was written.
        if RecipientsAuth.constantTimeEqual(previous.bytes, secret.bytes) { return .accepted(j, previous: previous) }
        let record = record?.vaultId == manifest.vaultId ? record : nil
        // Rule 1 (security review 2026-10, R4): anyone can encrypt a secret of
        // their own to the public keys; only a linked one is the vault's.
        guard RecipientsAuth.linkConnects(manifest.secretLink, from: previous, to: secret, vaultId: manifest.vaultId) else {
            return .refused("its previous secret is not linked to the vault's (format.md §2.1 secretLink): "
                + "not written by this vault's recipient change")
        }
        // Rule 3 (S0): this device saw the rotation into the current secret
        // finish; a journal now is one planted or put back by whoever kept the
        // outgoing secret (a removed device).
        if record?.saysRewrapFinished(for: secret) == true {
            return .refused("this device saw the change to the vault's current secret finish (format.md §3.3.1): "
                + "a journal put back or planted since")
        }
        // Rule 2 (S0): while the vault binds journals, only the one vault.json
        // binds under the current secret counts.
        if bindsJournals(manifest, secret: secret, record: record) {
            guard let tag = manifest.rewrapPending,
                  RecipientsAuth.verifyRewrapPending(tag, vaultId: manifest.vaultId, journal: data, secret: secret) else {
                return .refused("vault.json does not bind it (format.md §3.3.1 rewrapPending): "
                    + "not this vault's unfinished recipient change")
            }
        }
        return .accepted(j, previous: previous)
    }

    /// True when the vault binds its journals (format.md §3.3.1 rule 2):
    /// `rewrapPending` present, the feature named by `vault.json` or this
    /// device's recorded markers, or markers that do not check (a feature
    /// taken out without the key).
    static func bindsJournals(_ m: VaultManifest, secret: VaultSecret, record: RecipientsTrustRecord?) -> Bool {
        let feature = VaultManifest.rewrapPendingFeature
        return m.rewrapPending != nil || m.features.contains(feature)
            || record?.markers?.features.contains(feature) == true
            || RecipientsAuth.markersProblem(m, secret: secret, record: record) != nil
    }

    /// This vault's journal as judged now (`judgeJournal` on the file).
    func judgeJournal() -> JournalVerdict {
        guard let secret else { return .unreadable("the vault is locked") }
        let data: Data
        do { data = try FileIO.read(journalURL, maxBytes: BoundedRead.maxManifestBytes) } catch {
            if case VaultError.fileTooLarge = error { return .refused("\(error)") }
            return .unreadable("\(error)")
        }
        let record = (try? trustStore?.record(for: vaultId)) ?? nil
        return Self.judgeJournal(bytes: data, manifest: manifest, secret: secret, identities: identities, record: record)
    }

    /// True when nothing says a rotation into the current secret is pending:
    /// `vault.json` (as this value holds it) carries no `rewrapPending` and no
    /// journal exists. A trust record saved then says `rewrapFinished`.
    var rewrapSettled: Bool { manifest.rewrapPending == nil && !pendingRewrap }

    /// Sets `rewrapFinished` in this device's trust record when it already
    /// names the current secret, the list checks and nothing is pending
    /// (format.md §3.3.1 "Finished rotations"). Nothing else in the record
    /// changes: a reader that keeps no record keeps none, and a legacy record
    /// or one of an earlier secret waits for the next write (which saves the
    /// record, marker included, through `rememberRecipients`).
    func noteRewrapSettled() {
        guard let trustStore, let secret, case .verified(.unchanged) = recipientsStatus, !isReadOnly, rewrapSettled,
              var record = (try? trustStore.record(for: vaultId)) ?? nil, !record.rewrapFinished,
              case .signed(let keys) = record.anchor, (try? LinkPublicKeys(secret: secret)) == keys else { return }
        record.rewrapFinished = true
        try? trustStore.save(record)
    }

    /// Removes `rewrapPending` from `vault.json` (format.md §3.3.1 step 4), in
    /// one atomic write that tags the markers, only when the file on disk
    /// still holds this value's recipients, secret and intact markers.
    mutating func clearRewrapPending() throws {
        let secret = try requireSecret()
        var m = try Self.readManifest(FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))
        guard m.rewrapPending != nil else {
            manifest.rewrapPending = nil
            return
        }
        guard m.recipients.map(\.key) == manifest.recipients.map(\.key), m.vaultSecret == manifest.vaultSecret,
              m.markersIntact(secret: secret), Self.readOnlyReasons(m).isEmpty else {
            throw VaultError.manifestCorrupt("vault.json changed since it was opened; open the vault again")
        }
        m.rewrapPending = nil
        manifest = try Self.writeManifest(m, to: manifestURL, replacing: true, secret: secret)
    }

    /// Deletes a rewrap journal this device refuses (format.md §3.3.1
    /// "Refused journals"): one planted, put back after its change finished,
    /// or not a journal at all. It gave no secret, so nothing that verified
    /// stops verifying; deleting it lets recipient changes, repairs and blob
    /// collection run again. When this device's trust record says the change
    /// to the current secret finished, a `rewrapPending` left in `vault.json`
    /// (a put-back copy) is removed too.
    ///
    /// - Returns: why the journal was refused; nil when there was none.
    /// - Throws: `rewrapJournalKept` for a journal this device accepts (finish
    ///   it with `resumeRewrap`) or cannot read now; the checks of
    ///   `requireWritable` (a list that does not check, a read-only vault).
    @discardableResult
    public mutating func discardRefusedJournal() throws -> String? {
        let secret = try requireReadable()
        try requireWritable()
        guard pendingRewrap else { return nil }
        switch judgeJournal() {
        case .accepted:
            throw VaultError.rewrapJournalKept("it belongs to an unfinished recipient change: finish it "
                + "(sempere vault rewrap-resume)")
        case .unreadable(let why):
            throw VaultError.rewrapJournalKept("it cannot be read now (\(why)); only a journal that was read and "
                + "refused is discarded")
        case .refused(let why):
            let record = (try? trustStore?.record(for: vaultId)) ?? nil
            if record?.saysRewrapFinished(for: secret) == true { try clearRewrapPending() }
            try FileIO.remove(journalURL)
            previousSecret = nil
            journalProblem = nil
            journalRefused = false
            try? rememberRecipients()
            return why
        }
    }

    /// Whether a `rewrap-journal.json` received from a sync server may
    /// replace (or become) the local one (format.md §3.3.1 "Refused
    /// journals"; security review 2026-10, S9): nil when it may.
    ///
    /// A local journal may hold the only copy of the outgoing secret, so it
    /// is replaced only when this device refuses it and accepts the incoming
    /// one. Without the key nothing can be judged: an existing local journal
    /// is kept, and a new one is taken (it is judged when the vault opens).
    /// With the key, a journal this device refuses is never taken.
    ///
    /// - Parameters:
    ///   - data: the incoming bytes.
    ///   - local: the local journal's bytes; nil when there is none.
    ///   - manifest: the local `vault.json`'s bytes (as synced so far).
    ///   - vault: the local vault, opened with identities if possible.
    public static func incomingJournalProblem(_ data: Data, local: Data?, manifest: Data?, vault: Vault?) -> IncomingJournalProblem? {
        if let local, local == data { return nil }
        let keep = IncomingJournalProblem.keepLocal("the local rewrap journal is kept: it may hold the only copy of an "
            + "unfinished recipient change's outgoing secret (format.md §3.3.1)")
        guard let vault, vault.canRead, let manifest, let m = try? readManifest(manifest), m.vaultId == vault.vaultId,
              let secret = try? decryptSecret(m.vaultSecret, with: vault.identities) else {
            return local == nil ? nil : keep
        }
        let record = (try? vault.trustStore?.record(for: vault.vaultId)) ?? nil
        if case .refused(let why) = judgeJournal(bytes: data, manifest: m, secret: secret, identities: vault.identities, record: record) {
            return .refused(why)
        }
        guard let local else { return nil }
        if case .refused = judgeJournal(bytes: local, manifest: m, secret: secret, identities: vault.identities, record: record) {
            return nil
        }
        return keep
    }

    /// What to run while a journal blocks a change: finish it, or (when this
    /// device refuses it) discard it.
    var pendingRewrapAdvice: String {
        journalRefused
            ? "a rewrap journal this device refuses is there (\(journalProblem ?? "refused")): check it, then run "
                + "`sempere vault rewrap-discard`"
            : "a recipient change is unfinished: run `sempere vault rewrap-resume`"
    }
}
