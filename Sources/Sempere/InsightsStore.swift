import Age
import Foundation

// MARK: - The vault's insights folder (format.md §16; docs/design/1.2-note-insights.md §3.3, §3.5)
//
// One writer per file: a device writes only files named for its own id in the vault (`writerDevice`). Writes are
// vault writes (`requireWritable`: refused read-only, locked, with the recovery key, or for an untrusted list), are not
// recorded in the write ledger and are never taken through the epoch chain: a file is read only under the current key.
// Deletions are limited to: this device's own files (purge, "off"); files that open under a key from before a finished
// re-encryption; and files named for a device the vault removed (it appears in an earlier list of the vault's chain and
// is absent from the current one). A device never deletes a file of a device it has not heard of.

extension Vault {
    /// `insights/` (format.md §16).
    public static let insightsName = "insights"

    /// `<vault>/insights/`.
    public var insightsURL: URL { url.appendingPathComponent(Self.insightsName, isDirectory: true) }

    /// The bytes of `content` as the file `name`: format.md §4 framing with the label `insights` and the file name in
    /// the tag, encrypted to the current `v_e` in one stanza.
    public func sealInsights(_ content: InsightsFileContent, name: InsightsFileName) throws -> Data {
        let json = try InsightsCodec.encode(content)
        guard json.count <= name.kind.maxBytes else { throw InsightsFileError.tooLarge }
        let body = try BodyFraming.frame(json: json, noteId: InsightsCodec.tagScope, filename: name.fileName, secret: try requireSecret())
        let sealed = try encrypt(body)
        guard sealed.count <= name.kind.maxBytes + 4096 else { throw InsightsFileError.tooLarge }
        return sealed
    }

    /// The content of the bytes of file `name`, read under the CURRENT key only (format.md §16.6): decrypted with the
    /// current vault identity, its tag verified under the current `tagKey`, decompressed within the kind's bound,
    /// decoded and validated.
    public func openInsights(_ data: Data, name: InsightsFileName) throws -> InsightsFileContent {
        guard let secret else { throw InsightsFileError.cannotWrite("the vault is locked") }
        guard data.count <= name.kind.maxBytes + 4096 else { throw InsightsFileError.tooLarge }
        let plain: Data
        do { plain = try AgeFile.decrypt(data, with: identities) } catch { throw InsightsFileError.undecryptable }
        return try decodeInsightsBody(plain, name: name, key: secret)
    }

    func decodeInsightsBody(_ plain: Data, name: InsightsFileName, key: VaultEpochKey) throws -> InsightsFileContent {
        let unframed: BodyFraming.Unframed
        do {
            unframed = try BodyFraming.unframe(plain, noteId: InsightsCodec.tagScope, filename: name.fileName, secret: key)
        } catch { throw InsightsFileError.framing }
        let json: Data
        do { json = try Gzip.decompress(unframed.gzip, maxOutput: name.kind.maxBytes) } catch { throw InsightsFileError.gzip }
        return try InsightsCodec.decode(json, name: name)
    }

    /// The content and epoch of the bytes of file `name` when they open under an EARLIER key this vault value holds
    /// (never the current one): what re-sealing reads (format.md §16.6). Nil otherwise.
    public func openInsightsUnderEarlierKey(_ data: Data, name: InsightsFileName) -> (epoch: Int, content: InsightsFileContent)? {
        guard data.count <= name.kind.maxBytes + 4096 else { return nil }
        for (epoch, key) in keyring?.knownKeys() ?? [] where epoch < manifest.epoch {
            guard let identity = try? key.vaultIdentity(),
                  let plain = try? AgeFile.decrypt(data, with: [NativeIdentity.mlkem768x25519(identity)]),
                  let content = try? decodeInsightsBody(plain, name: name, key: key) else { continue }
            return (epoch, content)
        }
        return nil
    }

    /// True when the bytes decrypt and verify under the key of an epoch below `m` this value holds (format.md §16.6:
    /// deleted below a finished re-encryption). Only framing is checked: a file under such a key goes, whatever it holds.
    public func insightsUnderEpoch(below m: Int, _ data: Data, name: InsightsFileName) -> Bool {
        guard data.count <= name.kind.maxBytes + 4096 else { return false }
        return (keyring?.knownKeys() ?? []).contains { epoch, key in
            guard epoch < m, let identity = try? key.vaultIdentity(),
                  let plain = try? AgeFile.decrypt(data, with: [NativeIdentity.mlkem768x25519(identity)]) else { return false }
            return (try? BodyFraming.unframe(plain, noteId: InsightsCodec.tagScope, filename: name.fileName, secret: key)) != nil
        }
    }

    /// The ids of devices this vault removed (format.md §16.6): listed somewhere on its verified chain (or in the
    /// manifest's history of additions) and absent from the current list. A device on an older list does not know of
    /// devices that joined since, so they are never in this set.
    public func removedInsightsDevices() -> Set<DeviceID> {
        let current = Set(manifest.devices.compactMap { $0.id ?? DeviceIds.id(of: $0.fingerprint) })
        var out = Set<DeviceID>()
        for fp in DeviceIds.everListed(manifest: manifest, chain: verifiedChain) {
            let id = DeviceIds.id(of: fp)
            if !current.contains(id), let d = DeviceID(id) { out.insert(d) }
        }
        return out
    }

    /// What the vault's `insights.enabled` says (format.md §16.6, docs/settings-sync.md): `on` syncs `insights/`;
    /// `off` (an explicit `false` at the top level) deletes it here and on targets; `unset` (no value, or a file this
    /// device cannot read) leaves it alone and syncs none of it.
    public enum InsightsMode: String, Hashable, Sendable { case on, off, unset }

    public func insightsMode() -> InsightsMode {
        guard canRead, let s = (try? readSharedSettings()) ?? nil else { return .unset }
        switch s.value(SettingSlotKey("insights.enabled")) {
        case .bool(true)?: return .on
        case .bool(false)?: return .off
        default: return .unset
        }
    }

    /// Deletes this working copy's insights files that open under a key from before a finished re-encryption
    /// (format.md §16.6), with the per-device summaries of `removeSummariesBelowReencryption`. Returns their paths.
    @discardableResult
    public func removeInsightsBelowReencryption() -> [String] {
        guard !isReencryptPending, let m = reencryptEpoch, !isReadOnly, case .device = openedWith else { return [] }
        let run = { () -> [String] in
            var out: [String] = []
            for name in InsightsStore.names(in: self.insightsURL) {
                let file = self.insightsURL.appendingPathComponent(name.fileName)
                guard let data = try? BoundedRead.contents(of: file, maxBytes: name.kind.maxBytes + 4096),
                      self.insightsUnderEpoch(below: m.epoch, data, name: name), (try? FileIO.remove(file)) != nil else { continue }
                out.append("\(Self.insightsName)/\(name.fileName)")
            }
            return out.sorted()
        }
        return (try? epochWriteLock.withLock(timeout: 30, run)) ?? []
    }
}

/// Every insights file of a vault as this device reads it (current key only), sorted out by kind and writer.
public struct InsightsSnapshot: Sendable {
    /// Per note, every writer's valid file (tombstones included).
    public var notes: [UUID: [DeviceID: InsightsNoteFile]] = [:]
    public var maps: [DeviceID: InsightsMapFile] = [:]
    public var devices: [DeviceID: InsightsDeviceRecord] = [:]
    public var topics: [DeviceID: InsightsTopicsFile] = [:]
    /// Files named like insights files that were not taken, with why (verify's hints).
    public var ignored: [String: InsightsFileError] = [:]
    /// Every file taken, by name.
    public var files: [InsightsFileName] = []

    public init() {}

    /// The `gen` a reader shows for a note whose insight text hashes to `hash` (design §3.2): the best file holding a
    /// `gen` with that hash, else (stale) the latest `gen` of any hash; each time the later `written` first, then the
    /// device id. `current` says whether the hash matched.
    public func bestGen(for note: UUID, hash: String?) -> (gen: InsightsNoteFile.Gen, device: DeviceID, written: Int64, current: Bool)? {
        let files = (notes[note] ?? [:]).compactMap { d, f in f.gen.map { (d, f.written, $0) } }
            .sorted { ($0.1, $0.0.rawValue) > ($1.1, $1.0.rawValue) }
        if let hash, let hit = files.first(where: { $0.2.hash == hash }) { return (hit.2, hit.0, hit.1, true) }
        return files.first.map { ($0.2, $0.0, $0.1, false) }
    }

    /// The `emb` of `note` from the work device's file only (design §3.2).
    public func emb(for note: UUID, from device: DeviceID) -> InsightsNoteFile.Emb? { notes[note]?[device]?.emb }

    /// The work device's map, when it holds the role (not a tombstone).
    public func map(of device: DeviceID) -> InsightsMapFile? {
        guard let m = maps[device], !m.isTombstone else { return nil }
        return m
    }
}

/// Reads and writes `insights/` for a vault opened as a device (docs/design/1.2-note-insights.md §3.3, §4).
public struct InsightsStore: Sendable {
    public let vault: Vault

    public init(vault: Vault) { self.vault = vault }

    public var folder: URL { vault.insightsURL }

    /// The insights file names in `folder`, sorted (hidden and unknown names skipped).
    public static func names(in folder: URL) -> [InsightsFileName] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.compactMap(InsightsFileName.init).sorted()
    }

    /// Reads one file under the current key; nil when it is missing; throws why it was not taken.
    public func read(_ name: InsightsFileName) throws -> InsightsFileContent? {
        let file = folder.appendingPathComponent(name.fileName)
        guard FileIO.exists(file) else { return nil }
        if let size = FileIO.size(file), size > Int64(name.kind.maxBytes + 4096) { throw InsightsFileError.tooLarge }
        let data: Data
        do { data = try vault.readFile(file, maxBytes: name.kind.maxBytes + 4096) } catch { throw InsightsFileError.tooLarge }
        return try vault.openInsights(data, name: name)
    }

    /// Every file of the folder, read under the current key (`InsightsSnapshot`). Files of removed devices are left
    /// out (they are deleted by `removeRemovedDevices`).
    public func snapshot() -> InsightsSnapshot {
        var s = InsightsSnapshot()
        guard vault.canRead else { return s }
        let removed = vault.removedInsightsDevices()
        for name in Self.names(in: folder) {
            if removed.contains(name.device) {
                s.ignored[name.fileName] = .cannotWrite("written by a device removed from the vault")
                continue
            }
            do {
                guard let content = try read(name) else { continue }
                s.files.append(name)
                switch content {
                case .note(let f): if let id = name.noteId { s.notes[id, default: [:]][name.device] = f }
                case .map(let f): s.maps[name.device] = f
                case .device(let f): s.devices[name.device] = f
                case .topics(let f): s.topics[name.device] = f
                }
            } catch let e as InsightsFileError {
                s.ignored[name.fileName] = e
            } catch {
                s.ignored[name.fileName] = .invalid("\(error)")
            }
        }
        return s
    }

    /// This device's id in the vault, the only writer of files named for it.
    public func writer() throws -> DeviceID {
        guard let d = vault.writerDevice else {
            throw InsightsFileError.cannotWrite("insights are written only by a device listed in the vault, opened with its key")
        }
        return d
    }

    /// The `written` this device's own file `name` holds now (read under the current key), for `nextWritten`.
    func previousWritten(_ name: InsightsFileName) -> Int64? {
        (try? read(name))??.written
    }

    /// Writes `content` as this device's file of its kind (and note), replacing it atomically. `written` is set to
    /// `max(now, previous + 1)`. A vault write (`requireWritable`), made under the vault's write lock
    /// (`epochWriteLock`: the store's for a store vault, else the hidden lock file), which the sync engine's local
    /// insights changes take too (review of #50, M3). The lock is not reentrant: never call these holding it.
    @discardableResult
    public func write(_ content: InsightsFileContent, now: Date = Date()) throws -> InsightsFileName {
        try vault.requireWritable()
        let me = try writer()
        return try vault.epochWriteLock.withLock(timeout: 30) { try writeLocked(content, me: me, now: now) }
    }

    /// `write` with the lock held.
    func writeLocked(_ content: InsightsFileContent, me: DeviceID, now: Date) throws -> InsightsFileName {
        var content = content
        let name: InsightsFileName
        switch content {
        case .note(var f):
            guard let id = UUID(uuidString: f.noteId) else { throw InsightsFileError.invalid("noteId") }
            name = InsightsFileName(note: id, device: me)
            f.device = me.rawValue
            f.written = InsightsCodec.nextWritten(after: previousWritten(name), now: now)
            content = .note(f)
        case .map(var f):
            name = InsightsFileName(.map, device: me)
            f.device = me.rawValue
            f.written = InsightsCodec.nextWritten(after: previousWritten(name), now: now)
            content = .map(f)
        case .device(var f):
            name = InsightsFileName(.device, device: me)
            f.device = me.rawValue
            f.written = InsightsCodec.nextWritten(after: previousWritten(name), now: now)
            content = .device(f)
        case .topics(var f):
            name = InsightsFileName(.topics, device: me)
            f.device = me.rawValue
            f.written = InsightsCodec.nextWritten(after: previousWritten(name), now: now)
            content = .topics(f)
        }
        let sealed = try vault.sealInsights(content, name: name)
        try FileIO.createDirectory(folder)
        try FileIO.writeAtomically(sealed, to: folder.appendingPathComponent(name.fileName), replacing: true)
        return name
    }

    /// Replaces this device's sidecar of `note` with a tombstone (no `gen`, no `emb`; format.md §16.6), so a device
    /// bridging two targets cannot bring the old one back. Nothing when this device has no file for it.
    @discardableResult
    public func tombstone(note: UUID, now: Date = Date()) throws -> Bool {
        try vault.requireWritable()
        let me = try writer()
        let name = InsightsFileName(note: note, device: me)
        return try vault.epochWriteLock.withLock(timeout: 30) {
            guard FileIO.exists(folder.appendingPathComponent(name.fileName)) else { return false }
            if case .note(let f)? = try? read(name), f.isTombstone { return false }
            _ = try writeLocked(.note(InsightsNoteFile(noteId: note, device: me, written: 0)), me: me, now: now)
            return true
        }
    }

    /// Deletes every file of `insights/` here (format.md §16.6: what turning the feature off does). Returns the paths.
    @discardableResult
    public func purge() throws -> [String] {
        try vault.requireWritable()
        return try vault.epochWriteLock.withLock(timeout: 30) {
            var out: [String] = []
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            where InsightsFileName(name) != nil {
                try FileIO.remove(folder.appendingPathComponent(name))
                out.append("\(Vault.insightsName)/\(name)")
            }
            return out
        }
    }

    /// Deletes the files here named for devices the vault removed (format.md §16.6). A device's own `vault.json` is
    /// the one this vault value read, so its list stands here. Returns the paths.
    @discardableResult
    public func removeRemovedDevices() throws -> [String] {
        try vault.requireWritable()
        let removed = vault.removedInsightsDevices()
        guard !removed.isEmpty else { return [] }
        return try vault.epochWriteLock.withLock(timeout: 30) {
            var out: [String] = []
            for name in Self.names(in: folder) where removed.contains(name.device) {
                try FileIO.remove(folder.appendingPathComponent(name.fileName))
                out.append("\(Vault.insightsName)/\(name.fileName)")
            }
            return out
        }
    }

    /// Re-seals this device's own files that open only under an earlier key, under the current key (format.md §16.6;
    /// no model work), keeping their content. Returns the paths re-sealed.
    @discardableResult
    public func resealOwn(now: Date = Date()) throws -> [String] {
        try vault.requireWritable()
        let me = try writer()
        return try vault.epochWriteLock.withLock(timeout: 30) {
            var out: [String] = []
            for name in Self.names(in: folder) where name.device == me {
                let file = folder.appendingPathComponent(name.fileName)
                guard let data = try? vault.readFile(file, maxBytes: name.kind.maxBytes + 4096),
                      (try? vault.openInsights(data, name: name)) == nil,
                      let old = vault.openInsightsUnderEarlierKey(data, name: name) else { continue }
                // Below a finished re-encryption a file under an older key goes instead (format.md §16.6).
                if let m = vault.reencryptEpoch?.epoch, !vault.isReencryptPending, old.epoch < m {
                    try FileIO.remove(file)
                    continue
                }
                // A device's own files are never replaced from a target or a copy (local truth, review of #50, M2),
                // and a `titleOp` counts only when the note's history holds it as this device's (`ownTitleOp`).
                _ = try writeLocked(old.content, me: me, now: now)
                out.append("\(Vault.insightsName)/\(name.fileName)")
            }
            return out
        }
    }
}
