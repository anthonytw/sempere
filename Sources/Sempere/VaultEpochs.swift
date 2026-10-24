import Age
import Crypto
import Foundation

// Vaults of several epochs (docs/design/key-hierarchy.md §5.2.1, §5.3; format.md §15.6, §15.14; phase
// KH3): the keys of earlier epochs, read from the epoch records in `epochs/`, and the acceptance rule
// that decides which files under them a reader takes.

/// Why a vault file under an earlier key is not taken (design §5.3 rule 4, §5.8): it is **set aside**,
/// kept and never placed.
public enum SetAsideReason: String, Hashable, Sendable, Codable {
    /// Under an earlier epoch's key, and the record that closed that epoch does not list its path.
    case notSealed = "not-sealed"
    /// The record that closed its epoch lists its path with other bytes.
    case bytesDiffer = "bytes-differ"
    /// Under the key of an epoch that is not on this device's chain (one a takeover dropped).
    case dropped
    /// Under an epoch key from before a finished re-encryption whose seal this device can no longer read (its
    /// record is gone, design §7.2): every accepted file was re-encrypted, so this copy is superseded or stale.
    case beforeReencryption = "before-reencryption"

    /// One line for people.
    public var text: String {
        switch self {
        case .notSealed: return "written under an earlier key after the device change that closed it (not sealed)"
        case .bytesDiffer: return "sealed by a device change with other bytes"
        case .dropped: return "written under the key of a device change that a takeover dropped"
        case .beforeReencryption: return "from before a finished re-encryption (every accepted file was re-encrypted)"
        }
    }
}

/// One earlier epoch whose key this vault value holds.
struct OlderEpoch: Sendable {
    var epoch: Int
    var epochId: Data
    var key: VaultEpochKey
    /// `V_j`, to decrypt its files.
    var identity: NativeIdentity
    /// Its sealed set (path → SHA-256 hex), from the record whose parent it is; nil for an epoch off the
    /// chain (its files are set aside whatever they are).
    var sealed: [String: String]?
    /// SHA-256 of this epoch's own record file, as the record above it binds it (format.md §15.6); nil off
    /// the chain.
    var recordHash: Data?
    /// Why a file under this key is set aside when `sealed` is nil: `.dropped` (off the chain), or
    /// `.beforeReencryption` (on the chain below a finished re-encryption whose record is gone, KH6).
    var unsealedReason: SetAsideReason = .dropped

    init(epoch: Int, epochId: Data, key: VaultEpochKey, sealed: [String: String]?, recordHash: Data? = nil,
         unsealedReason: SetAsideReason = .dropped) throws {
        self.epoch = epoch; self.epochId = epochId; self.key = key; self.sealed = sealed; self.recordHash = recordHash
        self.unsealedReason = unsealedReason
        identity = .mlkem768x25519(try key.vaultIdentity())
    }
}

/// The keys of the earlier epochs of a vault's chain (design §5.3): read from the epoch records newest
/// first, each record giving its parent's key, sealed set and the SHA-256 of the parent's own record, only
/// as far as a reader needs them. Every record below the current one must hash to what the record above it
/// says (format.md §15.6): the current one is bound by `vault.json`'s `epochRecordHash`, so a holder of an
/// earlier key cannot rewrite an earlier sealed set (review M1). A record that is missing, does not hash
/// to its link or does not open stops the walk: the keys below it are unknown, and files under them are
/// **pending** (rule 3). Shared by a `Vault` value and its copies.
final class EpochKeyring: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let vaultId: UUID
    /// The chain's epoch ids, epoch 1 first, up to the current epoch.
    private let chainIds: [Data]
    private let withoutLinks: Bool
    private var loaded: [OlderEpoch] = []
    /// The epoch whose record is opened next, and its key.
    private var next: (epoch: Int, key: VaultEpochKey, recordHash: Data?)?
    private var stoppedEarly = false
    /// Keys of epochs off the chain (this device's ledger), tried last.
    private var offChain: [OlderEpoch] = []
    /// Keys of epochs on the chain that no record gives (KH6, design §7.2): a re-encryption record carries no
    /// parent key, so the keys below it come from its bound journal while it is pending, and from this device's
    /// own ledger (every epoch it pinned) after. By `epochId`.
    private var fallback: [Data: (epoch: Int, key: VaultEpochKey)] = [:]
    /// A parent the walk could not open for want of its key (below a re-encryption record): resumed when a
    /// fallback key for it is added.
    private var waiting: EpochRecordParent?
    /// The latest re-encryption epoch on the chain when it is finished (no journal pending, design §7.1 step 7):
    /// the records below it are deleted everywhere, so a walk that stops below it is not "incomplete" (files under
    /// the keys this device still holds read as set aside `beforeReencryption`, never pending).
    private var finishedReencryption: Int?

    /// - Parameters:
    ///   - chainIds: the verified chain's ids, epoch 1 first.
    ///   - parent: the current record's `parent` (its key and the sealed set of the epoch before).
    init(url: URL, vaultId: UUID, chainIds: [Data], parent: EpochRecordParent?, withoutLinks: Bool) {
        self.url = url; self.vaultId = vaultId; self.chainIds = chainIds; self.withoutLinks = withoutLinks
        guard let parent else { return }
        guard let key = parent.key else {
            // A re-encryption record carries no parent key (KH6): its keys come from the journal or the ledger.
            if chainIds.count >= 2, parent.epochId == chainIds[chainIds.count - 2] { waiting = parent }
            stoppedEarly = parent.epoch >= 1
            return
        }
        guard chainIds.count >= 2, key.epochId == chainIds[chainIds.count - 2],
              let older = try? OlderEpoch(epoch: parent.epoch, epochId: key.epochId, key: key, sealed: parent.sealed,
                                          recordHash: parent.recordHash) else {
            stoppedEarly = parent.epoch >= 1
            return
        }
        loaded = [older]
        next = parent.epoch >= 2 ? (parent.epoch, key, parent.recordHash) : nil
    }

    /// Keys of epochs on the chain that no record gives (a bound journal's, this device's own pinned ones): used
    /// where a re-encryption record carries no parent key. Keys whose id is not the chain's at their epoch are
    /// ignored.
    func addFallback(_ keys: [(epoch: Int, key: VaultEpochKey)]) {
        lock.lock(); defer { lock.unlock() }
        for (e, k) in keys where e >= 1 && e <= chainIds.count && chainIds[e - 1] == k.epochId { fallback[k.epochId] = (e, k) }
        resumeWaiting()
    }

    /// Marks the latest re-encryption epoch `m` of the chain finished (see `finishedReencryption`).
    func setFinishedReencryption(_ m: Int) {
        lock.lock(); defer { lock.unlock() }
        finishedReencryption = m
        resumeWaiting()
        settleBelowFinished()
    }

    /// The fallback key of the parent the walk waits for, when it is there now: the walk goes on (lock held).
    private func resumeWaiting() {
        guard let parent = waiting, let f = fallback[parent.epochId],
              let older = try? OlderEpoch(epoch: parent.epoch, epochId: parent.epochId, key: f.key, sealed: parent.sealed,
                                          recordHash: parent.recordHash) else { return }
        waiting = nil
        loaded.append(older)
        next = parent.epoch >= 2 ? (parent.epoch, f.key, parent.recordHash) : nil
        stoppedEarly = false
    }

    /// Below a finished re-encryption (lock held): when the walk has stopped, the keys this device still holds for
    /// epochs below the last one loaded are added without a seal (their files are set aside `beforeReencryption`),
    /// and the walk is not incomplete.
    private func settleBelowFinished() {
        guard let m = finishedReencryption, stoppedEarly, next == nil else { return }
        let lowest = loaded.last?.epoch ?? chainIds.count
        guard lowest <= m else { return }
        let have = Set(loaded.map(\.epochId))
        for (id, f) in fallback.sorted(by: { $0.value.epoch > $1.value.epoch }) where f.epoch < lowest && !have.contains(id) {
            if let o = try? OlderEpoch(epoch: f.epoch, epochId: id, key: f.key, sealed: nil, unsealedReason: .beforeReencryption) {
                loaded.append(o)
            }
        }
        stoppedEarly = false
        waiting = nil
    }

    /// Adds keys of epochs that are not on the chain (set aside whatever they hold).
    func addOffChain(_ keys: [(epoch: Int, key: VaultEpochKey)]) {
        lock.lock(); defer { lock.unlock() }
        let known = Set(loaded.map(\.epochId) + offChain.map(\.epochId) + chainIds)
        for (e, k) in keys where !known.contains(k.epochId) {
            if let o = try? OlderEpoch(epoch: e, epochId: k.epochId, key: k, sealed: nil) { offChain.append(o) }
        }
    }

    /// True when a record on the way could not be read: some earlier keys are unknown (files under them
    /// are pending, never set aside or accepted).
    var isIncomplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return stoppedEarly
    }

    /// The first value `body` gives for an earlier epoch, newest first, opening records only until then;
    /// then the off-chain keys.
    func first<T>(_ body: (OlderEpoch) throws -> T?) rethrows -> T? {
        var i = 0
        while let o = epoch(at: i) {
            if let v = try body(o) { return v }
            i += 1
        }
        lock.lock()
        let off = offChain
        lock.unlock()
        for o in off { if let v = try body(o) { return v } }
        return nil
    }

    /// Every earlier epoch on the chain whose key could be read, newest first.
    func all() -> [OlderEpoch] {
        var out: [OlderEpoch] = []
        var i = 0
        while let o = epoch(at: i) { out.append(o); i += 1 }
        return out
    }

    /// The off-chain keys.
    func offChainEpochs() -> [OlderEpoch] {
        lock.lock(); defer { lock.unlock() }
        return offChain
    }

    /// The `i`-th earlier epoch (0: the one before the current), opening one more record when needed.
    private func epoch(at i: Int) -> OlderEpoch? {
        lock.lock(); defer { lock.unlock() }
        while loaded.count <= i {
            guard let (j, key, expected) = next else { return nil }
            next = nil
            // Record j holds K_{j-1} and the sealed set of epoch j-1.
            let name = EpochRecord.fileName(epoch: j, epochId: key.epochId)
            let path = Vault.epochsName + "/" + name
            guard let data = try? (withoutLinks
                    ? BoundedRead.contents(under: url, path, maxBytes: EpochRecord.maxBytes)
                    : BoundedRead.contents(of: url.appendingPathComponent(path), maxBytes: EpochRecord.maxBytes)),
                  let expected, Vault.epochMutations.contains(.olderRecordNotHashChecked)
                    || Data(SHA256.hash(data: data)) == expected,
                  let record = try? EpochRecord.open(data, key: key, vaultId: vaultId, epoch: j),
                  j - 1 >= 1, chainIds.count >= j, record.epochId == chainIds[j - 1],
                  let parent = record.parent, parent.epochId == chainIds[j - 2] else {
                stoppedEarly = true
                settleBelowFinished()
                if loaded.count > i { break }
                return nil
            }
            // A re-encryption record carries no parent key (KH6): the journal's, or this device's own.
            guard let pk = parent.key ?? fallback[parent.epochId]?.key, pk.epochId == chainIds[j - 2],
                  let older = try? OlderEpoch(epoch: j - 1, epochId: pk.epochId, key: pk, sealed: parent.sealed,
                                              recordHash: parent.recordHash) else {
                waiting = parent.key == nil ? parent : nil
                stoppedEarly = true
                settleBelowFinished()
                if loaded.count > i { break }
                return nil
            }
            loaded.append(older)
            next = j - 1 >= 2 ? (j - 1, pk, parent.recordHash) : nil
        }
        return loaded[i]
    }
}

/// Test-only switches that break one safeguard each (`EpochInvariantTests` requires each to fail an invariant
/// of design §11.2, so none is vacuous).
enum EpochMutation: Hashable, Sendable, CaseIterable {
    /// J3: a file under an earlier key is taken without the sealed-set check.
    case acceptUnsealed
    /// J1: catch-up ignores the ledger (re-encrypts nothing).
    case skipCatchUp
    /// J6: catch-up replaces a file without setting the old bytes aside.
    case replaceWithoutSettingAside
    /// J8: catch-up replaces before verifying, with another body.
    case corruptReencryption
    /// J2, J5a: a writer keeps the previous epoch's key for its writes.
    case writeUnderOldKey
    /// J3 (review M1): a record below the current one is taken without checking its hash link.
    case olderRecordNotHashChecked
    /// J3 (§11.2): catch-up by device id instead of the ledger: an unaccepted revision under an earlier key whose
    /// name carries this device's id is re-encrypted as if it were its own.
    case catchUpByDeviceId
    /// J1 (§11.2, "ledger pruned on upload"): an entry goes as soon as it is written.
    case ledgerPrunedOnWrite
    /// J3 (§11.2, "a dropped epoch's sealed set honored"): a file under the key of an epoch a takeover dropped is
    /// accepted.
    case droppedEpochAccepted
    /// J4 (review of #86, M1): a record whose bytes are not the ones vault.json names refuses the vault.json (as
    /// before the fix), so the device rolls the target back and stays behind.
    case recordByNameOnly
    /// J4 (KH4): two takeovers are settled by which a device met first, not by `epochId`.
    case takeoverByArrival
    /// J9 (KH6, "the skip-complete-files check inverted"): the re-encryption pass skips what it must do, so it
    /// never finishes.
    case reencryptSkipInverted
    /// J7 (KH6): old blob names are never deleted (by the pass or by sync).
    case keepOldBlobNames
    /// J7 (KH6): epoch records below a finished re-encryption are kept (here, and on targets).
    case keepOldRecords
}

extension Vault {
    /// The active `EpochMutation`s (tests only).
    nonisolated(unsafe) static var epochMutations: Set<EpochMutation> = []
}

// MARK: - The acceptance rule (design §5.3)

/// The outcome of decrypting a vault file under the epochs a reader holds.
enum EpochOpened {
    /// It decrypted under `key`: the current epoch's (`older` nil) or an earlier one's.
    case opened(plain: Data, key: VaultEpochKey, older: OlderEpoch?)
    /// No key this device holds decrypts it, and a record on the chain could not be read: it may be under
    /// an earlier key whose record has not arrived (rule 3).
    case pending
    /// No key decrypts it.
    case undecryptable(String)
}

extension Vault {
    /// Decrypts `data` with the current vault identity first, then with each earlier epoch's (newest first),
    /// then with keys off the chain: at most one X-Wing decapsulation per epoch (design §5.3).
    func openUnderEpochs(_ data: Data) -> EpochOpened {
        guard let secret else { return .undecryptable("the vault is locked") }
        let first: Error
        do { return .opened(plain: try AgeFile.decrypt(data, with: identities), key: secret, older: nil) } catch {
            first = error
        }
        guard let keyring else { return .undecryptable("\(first)") }
        if let hit = keyring.first({ o -> (Data, OlderEpoch)? in
            (try? AgeFile.decrypt(data, with: [o.identity])).map { ($0, o) }
        }) {
            return .opened(plain: hit.0, key: hit.1.key, older: hit.1)
        }
        return keyring.isIncomplete ? .pending : .undecryptable("\(first)")
    }

    /// Why a file that decrypted and verified under `older` (an earlier epoch) is set aside; nil when the
    /// record that closed that epoch seals `path` with exactly these bytes (rule 2), or when `older` is nil
    /// (the current epoch, rule 1).
    func setAsideReason(_ older: OlderEpoch?, path: String, sha256 hex: @autoclosure () -> String) -> SetAsideReason? {
        guard let older, !Self.epochMutations.contains(.acceptUnsealed) else { return nil }
        guard let sealed = older.sealed else {
            return Self.epochMutations.contains(.droppedEpochAccepted) && older.unsealedReason == .dropped ? nil : older.unsealedReason
        }
        guard let digest = sealed[path] else { return .notSealed }
        return digest == hex() ? nil : .bytesDiffer
    }

    /// The earlier epochs this vault value holds keys for (loading every record on the chain).
    var olderEpochs: [OlderEpoch] { keyring?.all() ?? [] }

    /// The vault identities a blob may be decrypted with: the current one, then every earlier one.
    var blobIdentities: [any AgeIdentity] {
        identities + olderEpochs.map { $0.identity as any AgeIdentity }
            + (keyring?.offChainEpochs().map { $0.identity as any AgeIdentity } ?? [])
    }

    /// The epochs `blobSecrets` lists after the current one, in the same order.
    var blobOlderEpochs: [OlderEpoch] { olderEpochs + (keyring?.offChainEpochs() ?? []) }

    /// A path relative to the vault folder, as sealed sets and ledgers name files.
    static func notePath(_ note: UUID, _ file: String) -> String { "\(notesName)/\(note.uuidString.lowercased())/\(file)" }

    /// `notes/<id>/att/<file>`.
    static func blobPath(_ note: UUID, _ file: String) -> String {
        "\(notesName)/\(note.uuidString.lowercased())/\(attachmentsName)/\(file)"
    }
}
